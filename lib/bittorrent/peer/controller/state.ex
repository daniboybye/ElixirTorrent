defmodule Peer.Controller.State do
  
  alias Torrent.{Bitfield, PiecesStatistic, Uploader, Downloads}
  alias Peer.{Sender}
  alias Peer.Controller.FastExtension

  import Peer, only: [make_key: 2]#, key_to_id: 1, key_to_hash: 1

  @enforce_keys [:hash, :id, :fast_extension, :status, :pieces_count, :socket]
  defstruct [
    :hash,
    :id,
    :fast_extension,
    :status,
    :pieces_count,
    :socket,
    requests: MapSet.new(),
    rank: 0,
    bitfield: nil,
    interested: false,
    choke: true,
    interested_of_me: false,
    choke_me: true
  ]

  @typep bitfield :: Torrent.bitfield() | :all | :none | nil
  @typep subpiece :: {Torrent.index(), Torrent.begin(), Torrent.length()}
  @type rank :: {non_neg_integer(), Peer.id()} | nil

  @type t :: %__MODULE__{
          hash: Torrent.hash(),
          id: Peer.id(),
          fast_extension: FastExtension.type(),
          status: Peer.status(),
          pieces_count: pos_integer(),
          socket: port(),
          requests: MapSet.t(subpiece()),
          rank: non_neg_integer(),
          bitfield: bitfield(),
          interested: boolean(),
          choke: boolean(),
          interested_of_me: boolean(),
          choke_me: boolean()
        }

  @max_unanswered_requests 5

  @spec key(t()) :: Peer.key() 
  def key(state), do: make_key(state.hash, state.id)

  @spec rank(t()) :: rank() 
  def rank(state) do 
    if state.interested_of_me, do: {state.rank, state.id}
  end

  @spec reset_rank(t()) :: t()
  def reset_rank(state), do: %__MODULE__{state | rank: 0}

  @spec has_index?(t(), Torrent.index()) :: boolean()
  def has_index?(%__MODULE__{bitfield: :all}), do: true

  def has_index?(state, index) do
    case state.bitfield do
      <<_::bits-size(index), 1::1, _::bits>> ->
        true
      _ ->
        false
    end
  end

  @spec have(t(), Torrent.index()) :: t()
  def have(state, index) do
    unless has_index?(state, index), do: Sender.have(key(state), index)
    state
  end

  @spec choke(t()) :: t()
  def choke(state) do
    unless state.choke, do: Sender.choke(key(state))
    %__MODULE__{state | choke: true}
  end

  @spec unchoke(t()) :: t()
  def unchoke(state) do
    if state.choke, do: Sender.unchoke(key(state))
    %__MODULE__{state | choke: false}
  end

  @spec interested(t(), Torrent.index()) :: t()
  def interested(state, index) do
    %__MODULE__{state | status: index}
    |> check_interested()
  end

  @spec first_message(t(), non_neg_integer()) :: :ok
  def first_message(%__MODULE__{status: :seed, fast_extension: %FastExtension{}} = state, _) do
    Sender.have_all(key(state))
  end

  def first_message(%__MODULE__{fast_extension: %FastExtension{}} = state, 0) do
    Sender.have_none(key(state))
  end
      
  def first_message(state, _), do: Sender.bitfield(key(state))

  @spec cancel(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  def cancel(state, index, begin, length) do

    if member_request?(state, index, begin, length) do
      Sender.cancel(key(state), index, begin, length)
    end

    state
    |> delete_request(index, begin, length)
    |> make_request
  end

  @spec request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  def request(state, index, begin, length) do
    
    unless member_request?(state, index, begin, length) do
      Sender.request(key(state), index, begin, length)
    end

    state
    |> put_request(index, begin, length)
    |> make_request
  end

  @spec seed(t()) :: t() | {:error, :two_seeders, t()}
  def seed(%__MODULE__{bitfield: :all} = x), do: {:error, :two_seeders, x}

  def seed(state) do
    if state.interested, do: Sender.not_interested(key(state))
    
    %__MODULE__{state | bitfield: nil, status: :seed, interested: false}
  end

  @spec upload(t(),Torrent.length()) :: t()
  def upload(%__MODULE__{status: :seed} = state, n) do
    Map.update!(state, :rank, &(&1 + n))
  end

  def upload(state, _), do: state

  @spec handle_choke(t()) :: t()
  def handle_choke(state), do: %__MODULE__{state | choke_me: true}

  @spec handle_unchoke(t()) :: t()
  def handle_unchoke(state) do
    %__MODULE__{state | choke_me: false}
    |> make_request
  end

  @spec handle_interested(t()) :: t()
  def handle_interested(state) do
    %__MODULE__{state | interested_of_me: true}
  end

  @spec handle_not_interested(t()) :: t()
  def handle_not_interested(state) do
    %__MODULE__{state | interested_of_me: false}
    |> choke
  end

  @spec handle_have(t(), Torrent.index()) :: t() | {:error, :protocol_error, t()}
  def handle_have(%__MODULE__{bitfield: :all} = state, _) do 
    {:error, :protocol_error, state}
  end

  def handle_have(%__MODULE__{bitfield: x} = state, index) when x in [nil, :none] do
    %__MODULE__{state | bitfield: Bitfield.make(state.pieces_count)}
    |> handle_have(index)
  end

  def handle_have(state, index) do
    PiecesStatistic.inc(state.hash, index)

    state
    |> Map.update!(:bitfield, 
    fn <<prefix::bits-size(index), _::1, postfix::bits>> ->
      <<prefix::bits, 1::1, postfix::bits>>
    end)
    |> check_interested()
  end

  @spec handle_bitfield(t(), bitfield()) :: t() | {:error, :protocol_error, t()}
  def handle_bitfield(%__MODULE__{bitfield: x} = state, _)
      when not is_nil(x), do: {:error, :protocol_error, state}

  def handle_bitfield(%__MODULE__{status: :seed} = x, _), do: x

  def handle_bitfield(state, bitfield) do
    PiecesStatistic.update(state.hash, bitfield, state.pieces_count)

    %__MODULE__{state | bitfield: bitfield}
    |> check_interested()
  end

  @spec handle_request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t() | {:error, :protocol_error, t()} 
  def handle_request(state, index, begin, length) do
    if index < state.pieces_count and Bitfield.have?(state.hash, index) do
      
      if not state.choke or FastExtension.upload?(state.fast_extension, index) do
        Uploader.request(state.hash, state.id, index, begin, length)
      end

      state
    else
      {:error, :protocol_error, state}
    end
  end

  @spec handle_piece(t(), Torrent.index(), Torrent.begin(), Torrent.block()) :: t() | {:error, :protocol_error, t()}
  def handle_piece(state, index, begin, block) do
    length = byte_size(block)

    if member_request?(state, index, begin, length) do
      Downloads.response(state.hash, index, state.id, begin, block)

      state
      |> Map.update!(:rank, & &1 + length)
      |> delete_request(index, begin, length)
      |> make_request
    else
      {:error, :protocol_error, state}
    end
  end



  # DHT
  @spec handle_port(t(), non_neg_integer()) :: t()
  def handle_port(x, _port), do: x

  #FastExtansionMessage begin

  @spec handle_have_all(t()) :: t() | {:error, :two_seeds | :protocol_error, t()}
  def handle_have_all(%__MODULE__{bitfield: x} = state) when not is_nil(x) do
    {:error, :protocol_error, state}
  end
  
  def handle_have_all(%__MODULE__{status: :seed} = x), do: {:error, :two_seeders, x}

  def handle_have_all(state) do 
    PiecesStatistic.inc_all(state.hash)
    
    %__MODULE__{state | bitfield: :all}
    |> check_interested
  end 

  @spec handle_have_none(t()) :: t() | {:error, :protocol_error, t()}
  def handle_have_none(%__MODULE__{bitfield: x} = state) when not is_nil(x) do
    {:error, :protocol_error, state}
  end

  def handle_have_none(%__MODULE__{status: :seed} = state) do
    %__MODULE__{state | bitfield: :none}
    |> allowed_fast
  end

  def handle_have_none(state), do: %__MODULE__{state | bitfield: :none}

  @spec handle_reject(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t() | {:error, :protocol_error, t()}
  def handle_reject(state, index, begin, length) do
    if member_request?(state, index, begin, length) do
      
      Downloads.reject(state.hash, index, state.id, begin, length)

      state
      |> delete_request(index, begin, length)
      |> make_request
    else
      {:error, :protocol_error, state}
    end
  end

  #TODO
  @spec handle_suggest_piece(t(), Torrent.index()) :: t()
  def handle_suggest_piece(state, _index) do
    state
  end

  @spec handle_allowed_fast(t(), Torrent.index()) :: t()
  def handle_allowed_fast(state, index) do
    PiecesStatistic.allowed_fast(state.hash, index)
    
    state
    |> update_in( 
      [Access.key!(:fast_extension), Access.key!(:allowed_fast_me)],
      &MapSet.put(&1, index)  
    )
    |> make_request
  end

  @spec allowed_fast(t()) :: t()
  defp allowed_fast(%__MODULE__{fast_extension: %FastExtension{}} = state) do
    {:ok, {addr, _port}} = :inet.sockname(state.socket)

    set = AllowedFast.set(addr, state.hash, state.pieces_count)
    
    Enum.each(set, &Sender.allowed_fast(key(state), &1))

    put_in(
      state, 
      [Access.key!(:fast_extension), Access.key!(:allowed_fast)],
      set
    )
  end

  #FastExtansionMessage end

  @spec make_request(t()) :: t()
  defp make_request(
    %__MODULE__{interested: true, status: index} = state
  )
  when is_integer(index) do

    if not full_requests_queue?(state) and 
      (not state.choke_me or FastExtension.download?(state.fast_extension, index)) do
      pid = self()
      Downloads.request(state.hash, index, state.id, &GenServer.cast(pid, {:request, [&1, &2, &3]}))
    end

    state
  end

  defp make_request(state), do: state

  @spec check_interested(t()) :: t()
  defp check_interested(%__MODULE__{status: status} = state)
       when is_integer(status) do
    interested = has_index?(state, status)

    if interested != state.interested do
      Sender.interested(key(state), interested)
    end

    %__MODULE__{state | interested: interested}
    |> make_request
  end

  defp check_interested(state), do: state

  @spec subpiece(Torrent.index(), Torrent.begin(), Torrent.length()) :: subpiece()
  defp subpiece(index, begin, length), do: {index, begin, length}

  @spec put_request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  defp put_request(state, index, begin, length) do
    Map.update!(state, :requests, &MapSet.put(&1, subpiece(index,begin,length)))
  end

  @spec delete_request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  defp delete_request(state, index, begin, length) do
    Map.update!(state, :requests, &MapSet.delete(&1, subpiece(index,begin,length)))
  end

  @spec member_request?(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: boolean()
  defp member_request?(state, index, begin, length) do
    MapSet.member?(state.requests, subpiece(index,begin,length))
  end

  @spec full_requests_queue?(t()) :: boolean()
  defp full_requests_queue?(state), do: MapSet.size(state.requests) >= @max_unanswered_requests
end

defmodule Peer.Controller do
  use GenServer
  use Via

  require Logger

  alias Acceptor.BlackList
  alias __MODULE__.{State, FastExtension}
  alias Peer.Sender
  alias Torrent.Uploader

  import Peer, only: [make_key: 2, key_to_id: 1, key_to_hash: 1]

  @spec start_link({Peer.id(),Torrent.hash(),port(), Peer.reserved()}) :: GenServer.on_start()
  def start_link({id, hash, _socket, _reserved} = args) do
    GenServer.start_link(
      __MODULE__,
      args,
      name: via(make_key(hash, id))
    )
  end

  @spec have(Peer.key(), Torrent.index()) :: :ok
  def have(key, index), do: GenServer.cast(via(key), {:have, [index]})

  @spec interested(Peer.key(), Torrent.index()) :: :ok
  def interested(key, index) do
    GenServer.cast(via(key), {:interested, [index]})
  end

  @spec cancel(Torrent.hash(), Peer.id(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          :ok
  def cancel(hash, id, index, begin, length) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:cancel, [index, begin, length]})
  end

  @spec seed(Peer.key()) :: :ok
  def seed(key), do: GenServer.cast(via(key), {:seed, []})

  @spec choke(Torrent.hash(), Peer.id()) :: :ok
  def choke(hash, id) do 
    make_key(hash, id)
    |> via
    |> GenServer.cast({:choke,[]})
  end

  @spec unchoke(Torrent.hash(), Peer.id()) :: :ok
  def unchoke(hash, id) do 
    make_key(hash, id)
    |> via
    |> GenServer.cast({:unchoke,[]})
  end

  @spec rank(Peer.key()) :: State.rank()
  def rank(key), do: GenServer.call(via(key), :rank)

  @spec reset_rank(Peer.key()) :: :ok
  def reset_rank(key), do: GenServer.cast(via(key), {:reset_rank,[]})

  @doc """
  @spec request(
          Torrent.hash(),
          Peer.id(),
          Torrent.index(),
          Torrent.begin(),
          Torrent.length()
        ) :: :ok
  def request(hash, id, index, begin, length) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:request, [index, begin, length]})
  end
  """

  @spec piece(Torrent.hash(), Peer.id(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def piece(hash, id, index, begin, block) do
    key = make_key(hash, id)
    
    Sender.piece(key, index, begin, block)

    GenServer.cast(via(key), {:upload, [byte_size(block)]})
  end

  @spec handle_choke(Peer.key()) :: :ok
  def handle_choke(key), do: GenServer.cast(via(key), {:handle_choke,[]})

  @spec handle_unchoke(Peer.key()) :: :ok
  def handle_unchoke(key), do: GenServer.cast(via(key), {:handle_unchoke,[]})

  @spec handle_interested(Peer.key()) :: :ok
  def handle_interested(key) do
    GenServer.cast(via(key), {:handle_interested, []})
  end

  @spec handle_not_interested(Peer.key()) :: :ok
  def handle_not_interested(key) do
    GenServer.cast(via(key), {:handle_not_interested,[]})
  end

  @spec handle_have(Peer.key(), Torrent.index()) :: :ok
  def handle_have(key, piece_index) do
    GenServer.cast(via(key), {:handle_have, [piece_index]})
  end

  @spec handle_bitfield(Peer.key(), Torrent.bitfield()) :: :ok
  def handle_bitfield(key, bitfield) do
    GenServer.cast(via(key), {:handle_bitfield, [bitfield]})
  end

  @spec handle_request(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_request(key, index, begin, length) do
    GenServer.cast(via(key), {:handle_request, [index, begin, length]})
  end

  @spec handle_piece(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def handle_piece(key, index, begin, block) do
    GenServer.cast(via(key), {:handle_piece, [index, begin, block]})
  end

  @spec handle_cancel(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_cancel(key, index, begin, length) do
    Uploader.cancel(key_to_hash(key), key_to_id(key), index, begin, length)
  end

  @spec handle_port(Peer.key(), :inet.port_number()) :: :ok
  def handle_port(key, port) do
    GenServer.cast(via(key), {:handle_port, [port]})
  end

  @spec handle_have_all(Peer.key()) :: :ok
  def handle_have_all(key) do
    GenServer.cast(via(key), {:handle_have_all,[]})
  end

  @spec handle_have_none(Peer.key()) :: :ok
  def handle_have_none(key) do
    GenServer.cast(via(key), {:handle_have_none,[]})
  end

  @spec handle_suggest_piece(Peer.key(), Torrent.index()) :: :ok
  def handle_suggest_piece(key, index) do
    GenServer.cast(via(key),{:handle_suggest_piece, [index]})
  end

  @spec handle_reject(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          :ok
  def handle_reject(key, index, begin, length) do
    GenServer.cast(via(key), {:handle_reject, [index, begin, length]})
  end

  @spec handle_allowed_fast(Peer.key(), Torrent.index()) :: :ok
  def handle_allowed_fast(key, index) do
    GenServer.cast(via(key), {:handle_allowed_fast, [index]})
  end

  def init({id, hash, socket, reserved}) do
    %Torrent{} = torrent = Torrent.get(hash)

    state = %State{
      hash: hash,
      id: id,
      socket: socket,
      fast_extension: FastExtension.make(reserved),
      status: torrent.peer_status,
      pieces_count: torrent.last_index + 1
    }

    State.first_message(state, torrent.downloaded)

    {:ok, state}
  end

  def terminate({:shutdown, :protocol_error}, state) do
    BlackList.put(state.id)
  end

  def terminate(_, _), do: :ok

  def handle_call(:rank, _, state), do: {:reply, State.rank(state), state}

  def handle_cast({message, _}, %State{fast_extension: nil} = state) 
    when message in [:handle_have_all, :handle_have_none, :handle_suggest_piece, :handle_allowed_fast, :handle_reject] do
    {:stop, {:shutdown, :protocol_error}, state}
  end

  def handle_cast({fun, args}, state) do
    #if fun == :handle_unchoke, do: Logger.info "unchoke"
    #if fun == :handle_piece, do: Logger.info "piece"
    case fun do
      :handle_suggest_piece -> 
        Logger.info "suggest piece"
      _ ->
        :ok
    end
    
    case apply(State, fun, [state | args]) do
      {:error, reason, state} ->
        {:stop, {:shutdown, reason}, state}
      state ->
        {:noreply, state}
    end
  end
end

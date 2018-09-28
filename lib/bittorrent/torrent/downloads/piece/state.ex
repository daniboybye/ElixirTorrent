defmodule Torrent.Downloads.Piece.State do
  @enforce_keys [:index, :hash, :waiting]
  defstruct [:index, :hash, :waiting, :timer, :mode, monitoring: %{}, requests: []]

  alias Torrent.{Downloads.Piece.Request, Downloads.Piece, Swarm, FileHandle, PiecesStatistic, Server}

  require Logger

  @type timer :: reference() | nil
  @type waiting() :: list(Request.subpiece())

  @type t :: %__MODULE__{
    index: Torrent.index(),
    hash: Torrent.hash(),
    waiting: waiting(),
    timer: timer(),
    mode: Piece.mode(),
    monitoring: map(),
    requests: list(Request.t())
  }

  @subpiece_length trunc(:math.pow(2, 14))
  @endgame_mode_pending_block 2
  @timeout_request 60_000
  @timeout_get_request 100_000

  @compile {:inline, subpieces: 2}

  @spec make(Piece.args()) :: t()
  def make(args) do
    %__MODULE__{
      index: Keyword.fetch!(args, :index), 
      hash: Keyword.fetch!(args, :hash), 
      waiting: make_subpieces([], Keyword.fetch!(args, :length), 0)
    }
  end

  @spec download(t(), Piece.mode()) :: t()
  def download(%__MODULE__{waiting: []} = state, _) do
    Server.next_piece(state.hash)
    state
  end

  def download(state, mode) do
    Swarm.interested(state.hash, state.index)
    %__MODULE__{state | mode: mode, timer: unless(mode, do: new_timer())}
  end

  @spec make_subpieces(waiting(), Torrent.length(), Torrent.length() | 0) :: waiting()
  defp make_subpieces(res, len, pos) when pos + @subpiece_length >= len do
    [{pos, len - pos} | res]
  end

  defp make_subpieces(res, len, pos) do
    [{pos, @subpiece_length} | res]
    |> make_subpieces(len, pos + @subpiece_length)
  end

  @spec subpieces(t(), Peer.id()) :: MapSet.t(Request.subpiece())
  def subpieces(state, peer_id) do
    state.requests
    |> Enum.filter(& &1.peer_id == peer_id)
    |> Enum.into(MapSet.new(), & &1.subpiece)
  end

  @spec request(t(), Peer.id()) :: t()
  def request(%__MODULE__{waiting: []} = state, _), do: state

  def request(state, peer_id) do
    state
    |> Map.update!(
      :monitoring, 
        &Map.put_new_lazy(&1, peer_id, 
      fn -> Process.monitor(Peer.whereis(state.hash, peer_id)) end)
    )
    |> do_request(peer_id)
  end

  @spec do_request(t(), Peer.id()) :: t()
  defp do_request(%__MODULE__{mode: :endgame} = state, peer_id) do
    state.waiting
    |> Enum.take(@endgame_mode_pending_block)
    |> Enum.find_value(state,
        &state
        |> subpieces(peer_id)
        |> MapSet.member?(&1)
        |> unless(do: new_request(state, %Request{
          peer_id: peer_id,
          subpiece: &1
        }
    )))
  end

  defp do_request(state, peer_id) do
    [subpiece | waiting] = state.waiting
    
    if Enum.empty?(waiting), do: Server.next_piece(state.hash)
    
    cancel_timer(state.timer, :timeout)
    
    request = %Request{
      peer_id: peer_id,
      timer: requests_timer(peer_id),
      subpiece: subpiece
    }

    %__MODULE__{
      state
      | timer: unless(Enum.empty?(waiting), do: new_timer()),
        waiting: waiting
    }
    |> new_request(request)
  end  

  @spec response(t(), Peer.id, Torrent.begin(), Torrent.block()) :: t()
  def response(state, peer_id, begin, block) do
    length = byte_size(block)
    subpiece = {begin, length}

    {list, requests} = Enum.split_with(state.requests, &(&1.subpiece == subpiece))

    if Enum.empty?(list) and not Enum.member?(state.waiting, subpiece) do
      state
    else
      FileHandle.write(state.hash, state.index, begin, block)

      Enum.each(list, fn request ->
        cancel_request(request)

        unless peer_id == request.peer_id do
          Peer.cancel(state.hash, request.peer_id, state.index, begin, length)
        end
      end
      )
      
      state = %__MODULE__{
        state
        | requests: requests,
          waiting: List.delete(state.waiting, subpiece)
      }

      with %__MODULE__{mode: :endgame, waiting: []} <- state do
        Server.next_piece(state.hash)
        state
      end
    end
  end

  @spec reject(t(), Peer.id(), Torrent.begin(), Torrent.length()) :: t()
  def reject(state, peer_id, begin, length) do
    {list, requests} = 
      Enum.split_with(state.requests, &(&1.subpiece == {begin, length} and &1.peer_id == peer_id))

    %__MODULE__{state | requests: requests}
    |> do_reject(list)
  end

  @spec timeout(t(), Peer.id()) :: t()
  def timeout(state, peer_id) do
    {list, requests} = Enum.split_with(state.requests, & &1.peer_id == peer_id)
    
    %__MODULE__{state | requests: requests}
    |> do_reject(list)
  end
  
  @spec down(t(), reference()) :: t()
  def down(state, ref) do
    {peer_id, new_state} = pop_in(state, [Access.key!(:monitoring), ref])
    timeout(new_state, peer_id)
  end
  
  @spec do_reject(t(),list(Request.t())) :: t()
  defp do_reject(state, requests) do
    if not Enum.empty?(requests) and Enum.empty?(state.waiting) and is_nil(state.mode) do
      PiecesStatistic.make_priority(state.hash, state.index)
    end
    
    Enum.each(requests, &cancel_request/1)

    Map.update!(
      state,
      :waiting,
      fn x -> if(state.mode, do: x, else: Enum.map(requests, & &1.subpiece) ++ x) end
    )
  end

  @spec requests_timer(Peer.id()) :: reference()
  defp requests_timer(peer_id) do
    Process.send_after(self(), {:timeout, peer_id}, @timeout_request)
  end

  @spec cancel_request(Request.t()) :: :ok
  defp cancel_request(request) do
    cancel_timer(request.timer, {:timeout, request.peer_id})
  end

  @spec cancel_timer(Request.timer(), any()) :: :ok
  defp cancel_timer(nil, _), do: :ok

  defp cancel_timer(timer, message) do
    # cancel_timer is false => message is send
    unless Process.cancel_timer(timer) do
      receive do
        ^message -> :ok
      after
        0 -> :ok
      end
    else
      :ok
    end
  end

  @spec new_request(t(), Request.t()) :: t()
  defp new_request(state, request) do
    {begin, length} = request.subpiece
    
    Peer.request(state.hash, request.peer_id, state.index, begin, length)
    
    Map.update!(state, :requests, &[request | &1])
  end

  @spec new_timer() :: reference()
  defp new_timer, do: Process.send_after(self(), :timeout, @timeout_get_request)
end

defmodule Torrent.Downloads.Piece.State do
  @enforce_keys [:index, :hash, :waiting]
  defstruct [
    :index,
    :hash,
    :waiting,
    :requests_are_dealt,
    :downloaded,
    :timer,
    :mode,
    monitoring: %{},
    requests: []
  ]

  alias Torrent.{
    Downloads.Piece.Request,
    Downloads.Piece,
    FileHandle,
    PiecesStatistic,
    Model
  }

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

  @subpiece_length Piece.max_length()
  @endgame_mode_pending_block 2
  @timeout_request 60_000
  @timeout_get_request 100_000

  @compile {:inline, subpieces: 2}

  def make({hash, index}) do
    %__MODULE__{
      index: index,
      hash: hash,
      waiting: make_subpieces([], Model.piece_length(hash, index), 0)
    }
  end

  def download(%__MODULE__{waiting: []} = state, _, _) do
    IO.inspect(PiecesStatistic.get_status(state.hash, state.index),
      label: "choosing processing piece"
    )

    state.requests_are_dealt.()
    state
  end

  def download(state, downloaded, requests_are_dealt) do
    PiecesStatistic.set(state.hash, state.index, :processing)

    mode = Model.get(state.hash, :mode)

    %__MODULE__{
      state
      | mode: mode,
        timer: unless(mode, do: new_timer()),
        downloaded: downloaded,
        requests_are_dealt: requests_are_dealt
    }
  end

  @spec make_subpieces(waiting(), Torrent.length(), Torrent.length() | 0) :: waiting()
  defp make_subpieces(acc, len, pos) when pos + @subpiece_length >= len do
    [{pos, len - pos} | acc]
  end

  defp make_subpieces(acc, len, pos) do
    [{pos, @subpiece_length} | acc]
    |> make_subpieces(len, pos + @subpiece_length)
  end

  @spec subpieces(t(), Peer.id()) :: MapSet.t(Request.subpiece())
  def subpieces(state, peer_id) do
    state.requests
    |> Enum.filter(&(&1.peer_id == peer_id))
    |> Enum.into(MapSet.new(), & &1.subpiece)
  end

  # @spec request(t(), Peer.id(), Piece.callback()) :: t()
  def request(%__MODULE__{waiting: []} = state, _, _), do: state

  def request(state, peer_id, callback) do
    state
    |> Map.update!(
      :monitoring,
      &Map.put_new_lazy(&1, peer_id, fn -> Process.monitor(Peer.whereis(state.hash, peer_id)) end)
    )
    |> do_request(peer_id, callback)
  end

  # @spec do_request(t(), Peer.id(), Piece.callback()) :: t()
  defp do_request(%__MODULE__{mode: :endgame} = state, peer_id, callback) do
    state.waiting
    |> Enum.take(@endgame_mode_pending_block)
    |> Enum.find_value(
      state,
      &(state
        |> subpieces(peer_id)
        |> MapSet.member?(&1)
        |> unless(
          do:
            new_request(state, callback, %Request{
              peer_id: peer_id,
              subpiece: &1
            })
        ))
    )
  end

  defp do_request(state, peer_id, callback) do
    [subpiece | waiting] = state.waiting

    if Enum.empty?(waiting), do: state.requests_are_dealt.()

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
    |> new_request(callback, request)
  end

  @spec response(t(), Peer.id(), Torrent.begin(), Torrent.block()) :: t()
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
      end)

      state = %__MODULE__{
        state
        | requests: requests,
          waiting: List.delete(state.waiting, subpiece)
      }

      with %__MODULE__{mode: :endgame, waiting: []} <- state do
        state.requests_are_dealt.()
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
    {list, requests} = Enum.split_with(state.requests, &(&1.peer_id == peer_id))

    %__MODULE__{state | requests: requests}
    |> do_reject(list)
  end

  @spec down(t(), reference()) :: t()
  def down(state, ref) do
    {peer_id, new_state} = pop_in(state, [Access.key!(:monitoring), ref])
    timeout(new_state, peer_id)
  end

  @spec do_reject(t(), list(Request.t())) :: t()
  defp do_reject(state, requests) do
    if not Enum.empty?(requests) and Enum.empty?(state.waiting) and is_nil(state.mode) do
      PiecesStatistic.set(state.hash, state.index, nil)
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

  # @spec new_request(t(), Piece.callback(), Request.t()) :: t()
  defp new_request(state, callback, request) do
    {begin, length} = request.subpiece

    callback.(state.index, begin, length)

    Map.update!(state, :requests, &[request | &1])
  end

  @spec new_timer() :: reference()
  defp new_timer, do: Process.send_after(self(), :timeout, @timeout_get_request)
end

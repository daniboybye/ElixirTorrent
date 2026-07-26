defmodule Torrent.Downloads.Piece.State do
  @moduledoc """
  Pure state and transitions for a single-piece download worker.
  """

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
    Downloads.Piece,
    Downloads.Piece.Request,
    FileHandle,
    Model,
    PiecesStatistic,
    Swarm
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
  # In endgame, request remaining blocks redundantly, but cap the redundancy per block.
  @endgame_window 32
  @endgame_redundancy 3
  # Per-peer block request timeout. Shorter than the old 60s so a stalled peer
  # (common behind CGNAT / lossy dials) releases the in-flight slot sooner and
  # endgame redundancy can try another peer.
  @timeout_request 30_000
  @timeout_get_request 100_000
  # Piece worker with zero in-flight block requests cannot make progress until a
  # peer unchokes and calls Downloads.request/3. If every peer drops before that
  # (typical CGNAT churn: interested → disconnect ~5s, no unchoke), the old
  # 100s stall timer froze effective_max_parallel=1 pumps. Re-check every 10s
  # while requests=[]; abort when the swarm is empty (no one left to unchoke us).
  @timeout_idle_orphan 10_000

  @compile {:inline, subpieces: 2}

  def make({hash, index}) do
    %__MODULE__{
      index: index,
      hash: hash,
      waiting: make_subpieces([], Model.piece_length(hash, index), 0)
    }
  end

  def download(%__MODULE__{waiting: [], requests: []} = state, _, _) do
    state.requests_are_dealt.()
    state
  end

  # A prior attempt moved every subpiece into in-flight requests but never finished.
  # Re-queue them instead of telling the controller the piece is done.
  def download(
        %__MODULE__{waiting: [], requests: requests} = state,
        downloaded,
        requests_are_dealt
      )
      when requests != [] do
    waiting = Enum.map(requests, & &1.subpiece)
    Enum.each(requests, &cancel_request/1)

    download(
      %__MODULE__{state | waiting: waiting, requests: [], timer: nil},
      downloaded,
      requests_are_dealt
    )
  end

  def download(%__MODULE__{} = state, downloaded, requests_are_dealt) do
    PiecesStatistic.set(state.hash, state.index, :processing)

    mode = Model.get(state.hash, :mode)

    %__MODULE__{
      state
      | mode: mode,
        # Endgame has no overall stall timer; normal mode starts the short orphan
        # probe (not the 100s stall timer) until the first block request lands.
        timer: unless(mode, do: new_idle_orphan_timer()),
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

  @spec subpiece_request_count(t(), Request.subpiece()) :: non_neg_integer()
  defp subpiece_request_count(state, subpiece) do
    Enum.count(state.requests, &(&1.subpiece == subpiece))
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
    mine = subpieces(state, peer_id)

    state.waiting
    |> Enum.take(@endgame_window)
    |> Enum.find_value(state, fn subpiece ->
      already_requested_by_me? = MapSet.member?(mine, subpiece)
      redundancy_full? = subpiece_request_count(state, subpiece) >= @endgame_redundancy

      if already_requested_by_me? or redundancy_full? do
        false
      else
        new_request(state, callback, %Request{
          peer_id: peer_id,
          subpiece: subpiece
        })
      end
    end)
  end

  defp do_request(%__MODULE__{} = state, peer_id, callback) do
    [subpiece | waiting] = state.waiting

    if Enum.empty?(waiting), do: state.requests_are_dealt.()

    cancel_timer(state.timer, :idle_orphan_check)
    cancel_timer(state.timer, :timeout)

    request = %Request{
      peer_id: peer_id,
      timer: requests_timer(peer_id),
      subpiece: subpiece
    }

    %__MODULE__{
      state
      | timer: unless(Enum.empty?(waiting), do: new_stall_timer()),
        waiting: waiting
    }
    |> new_request(callback, request)
  end

  @spec response(t(), Peer.id(), Torrent.begin(), Torrent.block()) :: t()
  def response(%__MODULE__{} = state, peer_id, begin, block) do
    length = byte_size(block)
    subpiece = {begin, length}

    if valid_subpiece?(state, begin, length) do
      do_response(state, peer_id, begin, block, subpiece)
    else
      state
    end
  end

  defp do_response(%__MODULE__{} = state, peer_id, begin, block, subpiece) do
    length = byte_size(block)

    {list, requests} = Enum.split_with(state.requests, &(&1.subpiece == subpiece))

    if Enum.empty?(list) and not Enum.member?(state.waiting, subpiece) do
      # Endgame: a corrupt block may arrive first and drop the subpiece from
      # `waiting`; accept later duplicates so a good copy can overwrite disk.
      if state.mode == :endgame do
        FileHandle.write(state.hash, state.index, begin, block)
      end

      state
    else
      FileHandle.write(state.hash, state.index, begin, block)

      Enum.each(list, &cancel_duplicate_request(state, peer_id, begin, length, &1))

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

  @spec valid_subpiece?(t(), Torrent.begin(), Torrent.length()) :: boolean()
  defp valid_subpiece?(state, begin, length) do
    piece_len = Model.piece_length(state.hash, state.index)
    begin >= 0 and length > 0 and begin + length <= piece_len
  end

  @spec reject(t(), Peer.id(), Torrent.begin(), Torrent.length()) :: t()
  def reject(%__MODULE__{} = state, peer_id, begin, length) do
    {list, requests} =
      Enum.split_with(state.requests, &(&1.subpiece == {begin, length} and &1.peer_id == peer_id))

    %__MODULE__{state | requests: requests}
    |> do_reject(list)
  end

  @spec timeout(t(), Peer.id()) :: t()
  def timeout(%__MODULE__{} = state, peer_id) do
    Logger.debug(
      "[piece_download] hash=#{Torrent.hex_encoded_hash(state.hash)} index=#{state.index} peer=#{Peer.log_id(peer_id)} request_timeout"
    )

    {list, requests} = Enum.split_with(state.requests, &(&1.peer_id == peer_id))

    %__MODULE__{state | requests: requests}
    |> do_reject(list)
  end

  @spec down(t(), reference()) :: t() | {:abort, t()}
  def down(%__MODULE__{monitoring: monitoring} = state, ref) do
    case Enum.find(monitoring, fn {_peer_id, mon_ref} -> mon_ref == ref end) do
      {peer_id, _} ->
        state
        |> Map.update!(:monitoring, &Map.delete(&1, peer_id))
        |> timeout(peer_id)
        |> maybe_abort_orphan()

      nil ->
        state
    end
  end

  # Periodic probe while requests=[] — see @timeout_idle_orphan above.
  @spec idle_orphan_check(t()) :: t() | {:abort, t()}
  def idle_orphan_check(%__MODULE__{requests: [_ | _]} = state), do: state

  def idle_orphan_check(%__MODULE__{} = state) do
    if orphan_no_sources?(state) do
      {:abort, cancel_idle_orphan_timer(state)}
    else
      %{cancel_idle_orphan_timer(state) | timer: new_idle_orphan_timer()}
    end
  end

  @doc false
  @spec orphan_no_sources?(t()) :: boolean()
  def orphan_no_sources?(%__MODULE__{hash: hash, monitoring: monitoring}) do
    map_size(monitoring) == 0 and Swarm.count(hash) == 0
  end

  @spec maybe_abort_orphan(t()) :: t() | {:abort, t()}
  defp maybe_abort_orphan(%__MODULE__{requests: [_ | _]} = state), do: state

  defp maybe_abort_orphan(%__MODULE__{} = state) do
    if orphan_no_sources?(state) do
      {:abort, cancel_idle_orphan_timer(cancel_stall_timer(state))}
    else
      state
    end
  end

  @spec do_reject(t(), list(Request.t())) :: t()
  defp do_reject(state, requests) do
    if not Enum.empty?(requests) and Enum.empty?(state.waiting) and is_nil(state.mode) do
      PiecesStatistic.set(state.hash, state.index, nil)
    end

    Enum.each(requests, fn %Request{peer_id: peer_id, subpiece: {begin, length}} = request ->
      cancel_request(request)
      # Timeouts/rejects re-queue blocks locally but must release the peer
      # controller's reqq accounting — otherwise stale MapSet entries block
      # the download pipeline even though this worker no longer tracks them.
      Peer.cancel(state.hash, peer_id, state.index, begin, length)
    end)

    state
    |> Map.update!(:waiting, &requeue_rejected(&1, state, requests))
    |> restart_stall_timer()
  end

  # Normal mode: rejected/timed-out blocks go back to waiting. Endgame: re-queue
  # only when redundancy on that subpiece dropped below the cap so choked peers
  # do not strand blocks exclusively in-flight.
  @spec requeue_rejected(waiting(), t(), list(Request.t())) :: waiting()
  defp requeue_rejected(waiting, %__MODULE__{mode: nil}, requests) do
    Enum.map(requests, & &1.subpiece) ++ waiting
  end

  defp requeue_rejected(waiting, state, requests) do
    Enum.reduce(requests, waiting, fn %Request{subpiece: subpiece}, acc ->
      in_flight = Enum.count(state.requests, &(&1.subpiece == subpiece))

      if in_flight < @endgame_redundancy and subpiece not in acc do
        [subpiece | acc]
      else
        acc
      end
    end)
  end

  # Peer request timeouts re-queue blocks into waiting but previously left the
  # overall stall timer cancelled, so the worker could live forever in active_indices.
  defp restart_stall_timer(
         %__MODULE__{mode: nil, timer: nil, waiting: [_ | _], requests: []} = state
       ) do
    %{state | timer: new_stall_timer()}
  end

  defp restart_stall_timer(state), do: state

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
    if Process.cancel_timer(timer) do
      :ok
    else
      receive do
        ^message -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp cancel_duplicate_request(state, peer_id, begin, length, request) do
    cancel_request(request)

    if peer_id != request.peer_id do
      Peer.cancel(state.hash, request.peer_id, state.index, begin, length)
    end
  end

  # @spec new_request(t(), Piece.callback(), Request.t()) :: t()
  defp new_request(state, callback, request) do
    {begin, length} = request.subpiece

    callback.(state.index, begin, length)

    Map.update!(state, :requests, &[request | &1])
  end

  @spec new_idle_orphan_timer() :: reference()
  defp new_idle_orphan_timer,
    do: Process.send_after(self(), :idle_orphan_check, @timeout_idle_orphan)

  @spec new_stall_timer() :: reference()
  defp new_stall_timer, do: Process.send_after(self(), :timeout, @timeout_get_request)

  @spec cancel_idle_orphan_timer(t()) :: t()
  defp cancel_idle_orphan_timer(%__MODULE__{timer: timer} = state) do
    cancel_timer(timer, :idle_orphan_check)
    %{state | timer: nil}
  end

  @spec cancel_stall_timer(t()) :: t()
  defp cancel_stall_timer(%__MODULE__{timer: timer} = state) do
    cancel_timer(timer, :timeout)
    %{state | timer: nil}
  end

  @doc false
  @spec release_in_flight_requests(t()) :: :ok
  def release_in_flight_requests(%__MODULE__{} = state) do
    Enum.each(state.requests, fn %Request{peer_id: peer_id, subpiece: {begin, length}} = request ->
      cancel_request(request)
      Peer.cancel(state.hash, peer_id, state.index, begin, length)
    end)

    :ok
  end
end

defmodule Torrent.Downloads.Piece do
  use GenServer
  use Via

  alias __MODULE__.State
  alias Torrent.{FileHandle, PiecesStatistic}

  require Logger

  @type mode :: :endgame | nil
  @type callback_peer_request :: (Torrent.index(), Torrent.begin(), Torrent.length() -> any())

  @max_length trunc(:math.pow(2, 14))
  @compile {:inline, max_length: 0}

  def child_spec(args) do
    %{
      id: __MODULE__,
      restart: :transient,
      start: {__MODULE__, :start_link, args}
    }
  end

  @spec start_link(Torrent.hash(), Torrent.index()) :: GenServer.on_start()
  def start_link(hash, index) do
    GenServer.start_link(__MODULE__, {hash, index}, name: key(index, hash))
  end

  def max_length, do: @max_length

  def download(pid, downloaded, requests_are_dealt),
    do: GenServer.cast(pid, {:download, [downloaded, requests_are_dealt]})

  @spec request(Torrent.hash(), Torrent.index(), Peer.id(), callback_peer_request()) ::
          :ok | :error
  def request(hash, index, peer_id, callback) do
    # Resolve the via-name up front. A plain GenServer.cast to a dead
    # via-name silently succeeds (Registry lookup misses → cast is dropped),
    # which lets a peer pin its status to an index whose worker died and
    # never learn about it. Return :error so the caller can unpin and pick
    # a fresh piece on the next reconcile edge.
    case GenServer.whereis(key(index, hash)) do
      nil -> :error
      pid -> GenServer.cast(pid, {:request, [peer_id, callback]})
    end
  end

  # Cheap "does this piece still have unclaimed subpieces?" probe. Used by
  # Swarm.assign_peer_to_piece? to allow a peer whose pin is on a drained
  # piece to be re-assigned to a fresh one, and by tests to reason about
  # the piece-worker state without racing casts.
  @spec has_waiting?(Torrent.hash(), Torrent.index()) :: boolean()
  def has_waiting?(hash, index) do
    case GenServer.whereis(key(index, hash)) do
      nil -> false
      pid -> GenServer.call(pid, :has_waiting?, 1_000)
    end
  catch
    :exit, _ -> false
  end

  @spec whereis(Torrent.hash(), Torrent.index()) :: pid() | nil
  def whereis(hash, index), do: GenServer.whereis(key(index, hash))

  @spec response(
          Torrent.hash(),
          Torrent.index(),
          Peer.id(),
          Torrent.begin(),
          Torrent.block()
        ) :: :ok
  def response(hash, index, peer_id, begin, block) do
    GenServer.cast(
      key(index, hash),
      {:response, [peer_id, begin, block]}
    )
  end

  @spec reject(Torrent.hash(), Torrent.index(), Peer.id(), Torrent.begin(), Torrent.length()) ::
          :ok
  def reject(hash, index, peer_id, begin, length) do
    GenServer.cast(
      key(index, hash),
      {:reject, [peer_id, begin, length]}
    )
  end

  # Controller safety net: stop a piece worker that holds an active slot but has
  # no in-flight block requests (peer churn before first request/3).
  @spec abort_if_orphan(Torrent.hash(), Torrent.index(), keyword()) :: :ok
  def abort_if_orphan(hash, index, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    case GenServer.whereis(key(index, hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:abort_if_orphan, force?})
    end
  end

  def init(arg), do: {:ok, State.make(arg)}

  def handle_cast({:abort_if_orphan, force?}, state) do
    cond do
      state.requests != [] ->
        {:noreply, state}

      force? or State.orphan_no_sources?(state) ->
        abort_orphan_worker(state, :idle_orphan)

      true ->
        {:noreply, state}
    end
  end

  def handle_cast({fun, args}, state) do
    is_complete(apply(State, fun, [state | args]))
  end

  # Overall stall timeout — no progress on any subpiece for @timeout_get_request.
  # Before we die (transient supervisor → not restarted), fire the
  # requests_are_dealt closure so the controller frees this active-piece slot
  # and picks another. Without this wake edge, a stall silently drains
  # @max_parallel_pieces one by one until the pump has zero live pieces.
  def handle_info(:timeout, state) do
    abort_orphan_worker(state, :timeout)
  end

  # Short orphan probe while requests=[] — see State.@timeout_idle_orphan.
  def handle_info(:idle_orphan_check, state) do
    case State.idle_orphan_check(state) do
      {:abort, state} -> abort_orphan_worker(state, :idle_orphan)
      state -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case State.down(state, ref) do
      {:abort, state} -> abort_orphan_worker(state, :idle_orphan)
      state -> {:noreply, state}
    end
  end

  def handle_info({:timeout, peer_id}, state) do
    {:noreply, State.timeout(state, peer_id)}
  end

  # Sync probe used by Downloads.has_waiting?/2 and Swarm.assign_peer_to_piece?
  # to decide whether a peer pinned to this piece can be re-pinned. True while
  # any subpiece is still unclaimed (waiting) OR in-flight (requests) — in
  # endgame, waiting can be empty while requests hold every block on choked peers.
  def handle_call(:has_waiting?, _from, state) do
    {:reply, state.waiting != [] or state.requests != [], state}
  end

  def handle_call(:has_in_flight?, _from, state) do
    {:reply, state.requests != [], state}
  end

  # terminate/2 fallback for any non-normal exit (crash, {:shutdown, _}, etc.).
  # The controller pump is edge-triggered — every abnormal death must produce
  # an edge or the active-pieces slot leaks and the pump can starve. Normal
  # termination means the piece completed successfully; requests_are_dealt was
  # already fired earlier via State.do_request when the last subpiece was
  # handed out, so we skip that path.
  def terminate(:normal, _state), do: :ok
  def terminate(_reason, state), do: fire_dealt(state)

  # Verify-failed: hash-check on assembled piece was wrong. Same rationale as
  # :timeout above — free the pump slot before dying. Keep the state alive on
  # the stop tuple so terminate/2 has it as a fallback in case fire_dealt/1
  # here is skipped by a future refactor.
  defp is_complete(%State{requests: [], waiting: []} = state) do
    hash_hex = Torrent.hex_encoded_hash(state.hash)

    Logger.info(
      "[piece_download] hash=#{hash_hex} index=#{state.index} blocks_complete verifying"
    )

    if FileHandle.check?(state.hash, state.index) do
      Logger.info("[piece_download] hash=#{hash_hex} index=#{state.index} verified complete")
      state.downloaded.()
      {:stop, :normal, state}
    else
      Logger.info("[piece_download] hash=#{hash_hex} index=#{state.index} verify_failed")
      fire_dealt(state)
      {:stop, {:shutdown, :wrong_subpiece}, state}
    end
  end

  defp is_complete(state), do: {:noreply, state}

  # Best-effort invocation of the controller's pump-wake closure. It is
  # idempotent from the controller's perspective (posts {:next_piece, :rare};
  # the controller's handler is a capacity check). Guard against nil (worker
  # dying before `download/3` set the closure), non-fun (defensive), and any
  # closure crash.
  defp fire_dealt(%State{requests_are_dealt: cb}) when is_function(cb, 0) do
    try do
      cb.()
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp fire_dealt(_), do: :ok

  defp abort_orphan_worker(state, reason) do
    PiecesStatistic.set(state.hash, state.index, nil)
    fire_dealt(state)
    {:stop, {:shutdown, reason}, state}
  end

  @spec key(Torrent.index(), Torrent.hash()) :: GenServer.name()
  defp key(index, hash), do: via({index, hash})
end

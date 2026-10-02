defmodule Torrent.Downloads.Piece do
  @moduledoc """
  GenServer assembling one piece from BEP 3 block requests and verifying its SHA-1.
  """

  use GenServer
  use Via

  alias __MODULE__.State
  alias Torrent.{FileHandle, PiecesStatistic}

  require Logger

  @type mode :: :endgame | nil
  @type callback :: (-> term())
  @type callback_peer_request :: (Torrent.index(), Torrent.begin(), Torrent.length() -> any())

  @max_length trunc(:math.pow(2, 14))
  @compile {:inline, max_length: 0}

  @spec child_spec([Torrent.index()]) :: Supervisor.child_spec()
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

  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @spec download(pid(), callback(), callback()) :: :ok
  def download(pid, downloaded, requests_are_dealt),
    do: GenServer.cast(pid, {:download, [downloaded, requests_are_dealt]})

  @spec request(Torrent.hash(), Torrent.index(), Peer.id(), callback_peer_request()) ::
          :ok | :noop | :error
  def request(hash, index, peer_id, callback) do
    # Synchronous, bounded ack — no disk/network on this path (pure in-memory
    # piece state). Return :error when the worker is gone so the peer can
    # unpin; :noop when waiting=[] (drained/endgame skip) so the controller
    # does not inflate pending_requests without a wire callback; :ok when a
    # block was queued and the callback will cast {:request, _} to the peer
    # controller (BEP 10 reqq accounting — see Peer.Controller.State).
    case GenServer.whereis(key(index, hash)) do
      nil ->
        :error

      pid ->
        GenServer.call(pid, {:request, [peer_id, callback]}, 5_000)
    end
  catch
    :exit, _ -> :error
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

  # Same probe restricted to blocks nobody has claimed yet — see
  # `handle_call(:has_unclaimed?, ...)`.
  @spec has_unclaimed?(Torrent.hash(), Torrent.index()) :: boolean()
  def has_unclaimed?(hash, index) do
    case GenServer.whereis(key(index, hash)) do
      nil -> false
      pid -> GenServer.call(pid, :has_unclaimed?, 1_000)
    end
  catch
    :exit, _ -> false
  end

  # Same probe as `has_unclaimed?/2` but also true while this peer's own requests
  # are in flight here — see `handle_call({:serves_peer?, _}, ...)`.
  @spec serves_peer?(Torrent.hash(), Torrent.index(), Peer.id()) :: boolean()
  def serves_peer?(hash, index, peer_id) do
    case GenServer.whereis(key(index, hash)) do
      nil -> false
      pid -> GenServer.call(pid, {:serves_peer?, peer_id}, 1_000)
    end
  catch
    :exit, _ -> false
  end

  # Level-triggered mode upgrade from the torrent controller: a worker reads the
  # torrent's mode once (State.download/3), so pieces already in flight when the
  # torrent crosses into endgame would otherwise never get redundant sources.
  # Idempotent, and one-way — endgame is never revoked.
  @spec enter_endgame(Torrent.hash(), Torrent.index()) :: :ok
  def enter_endgame(hash, index) do
    case GenServer.whereis(key(index, hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:enter_endgame, []})
    end
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

  @spec init({Torrent.hash(), Torrent.index()}) :: {:ok, State.t()}
  def init(arg), do: {:ok, State.make(arg)}

  @spec handle_cast(term(), State.t()) ::
          {:noreply, State.t()}
          | {:stop, :normal, State.t()}
          | {:stop, {:shutdown, :idle_orphan | :timeout | :wrong_subpiece}, State.t()}
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
    finish_if_complete(apply(State, fun, [state | args]))
  end

  # Overall stall timeout — no progress on any subpiece for @timeout_get_request.
  # Before we die (transient supervisor → not restarted), fire the
  # requests_are_dealt closure so the controller frees this active-piece slot
  # and picks another. Without this wake edge, a stall silently drains
  # @max_parallel_pieces one by one until the pump has zero live pieces.
  @spec handle_info(term(), State.t()) ::
          {:noreply, State.t()} | {:stop, {:shutdown, :idle_orphan | :timeout}, State.t()}
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
  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, boolean() | :ok | :noop, State.t()}
  def handle_call(:has_waiting?, _from, state) do
    {:reply, state.waiting != [] or state.requests != [], state}
  end

  def handle_call(:has_in_flight?, _from, state) do
    {:reply, state.requests != [], state}
  end

  # Strictly "are there blocks left to hand out". Unlike :has_waiting? this
  # ignores in-flight requests, because a peer cannot be given a block that
  # another peer already holds — outside endgame, where duplicating them is
  # the whole point.
  def handle_call(:has_unclaimed?, _from, state) do
    {:reply, state.waiting != [], state}
  end

  # "Is this peer still working here?" — unclaimed blocks it could be handed, or
  # blocks it is already fetching. See `Swarm.pin_drained?/4` for why the second
  # half matters: a peer holding every in-flight request on a piece is the reason
  # that piece has nothing unclaimed left.
  def handle_call({:serves_peer?, peer_id}, _from, state) do
    serves? = state.waiting != [] or Enum.any?(state.requests, &(&1.peer_id == peer_id))
    {:reply, serves?, state}
  end

  # Sync ack for Downloads.request/4 — see request/4 above.
  def handle_call({:request, [peer_id, callback]}, _from, state) do
    new_state = State.request(state, peer_id, callback)
    {:reply, request_reply(state, new_state), new_state}
  end

  # terminate/2 fallback for any non-normal exit (crash, {:shutdown, _}, etc.).
  # The controller pump is edge-triggered — every abnormal death must produce
  # an edge or the active-pieces slot leaks and the pump can starve. Normal
  # termination means the piece completed successfully; requests_are_dealt was
  # already fired earlier via State.do_request when the last subpiece was
  # handed out, so we skip that path.
  @spec terminate(term(), State.t()) :: :ok
  def terminate(:normal, _state), do: :ok

  def terminate(_reason, state) do
    # Abnormal exit must drop peer-side reqq slots — controller accounting
    # survives piece-worker death and otherwise blocks the request pipeline.
    State.release_in_flight_requests(state)
    fire_dealt(state)
  end

  # Verify-failed: hash-check on assembled piece was wrong. Same rationale as
  # :timeout above — free the pump slot before dying. Keep the state alive on
  # the stop tuple so terminate/2 has it as a fallback in case fire_dealt/1
  # here is skipped by a future refactor.
  defp finish_if_complete(%State{requests: [], waiting: []} = state) do
    hash_hex = Torrent.hex_encoded_hash(state.hash)

    Logger.debug(
      "[piece_download] hash=#{hash_hex} index=#{state.index} blocks_complete verifying"
    )

    case FileHandle.check_audited(state.hash, state.index, State.received_digests(state)) do
      true ->
        Logger.debug("[piece_download] hash=#{hash_hex} index=#{state.index} verified complete")
        state.downloaded.()
        {:stop, :normal, state}

      {false, mismatches} ->
        report_verify_failure(state, hash_hex, mismatches)
        fire_dealt(state)
        {:stop, {:shutdown, :wrong_subpiece}, state}
    end
  end

  defp finish_if_complete(state), do: {:noreply, state}

  # A piece that fails its SHA-1 was assembled from bad bytes — but "bad bytes" has
  # two very different causes, and only one of them is a peer's fault:
  #
  #   * `:received` — the disk holds exactly what the peers sent (every block's
  #     CRC taken at receive time still matches), so the corruption was already in
  #     the data when it reached us: a peer with a bad store, a poisoner, or a
  #     middlebox/NAT mangling a UDP (uTP) datagram — uTP has no checksum of its
  #     own beyond UDP's weak 16-bit one.
  #   * `:local` — bytes on disk differ from what was received (a block that never
  #     landed, a misplaced or overwritten write), or a block was never accepted at
  #     all. The peers delivered correct data and punishing them would be wrong.
  #
  # Only in the `:received` case, and only when ONE peer supplied every block, is
  # that peer a provable culprit (libtorrent likewise attributes per block and
  # confirms by re-downloading from a single peer before it bans anyone); with
  # several contributors we cannot tell whose block was bad, so nobody is blamed
  # and the piece is simply retried. Whatever the verdict, the line below carries
  # the evidence (who sent how many blocks, duplicates, late replies) so a live
  # failure can be settled from the log alone.
  defp report_verify_failure(%State{} = state, hash_hex, mismatches) do
    verdict = verdict(state, mismatches)
    culprit = if verdict == :received, do: State.sole_contributor(state)

    Logger.warning(
      "[piece_download] hash=#{hash_hex} index=#{state.index} verify_failed " <>
        "verdict=#{verdict} blame=#{blame_label(culprit)} " <>
        "contributors=#{State.contributors_summary(state)} " <>
        "blocks=#{map_size(state.blocks)} unaccounted=#{State.unaccounted_blocks(state)} " <>
        "duplicates=#{state.duplicates} late=#{state.late} " <>
        "overwritten=#{state.overwritten} malformed=#{state.malformed} " <>
        "mismatch=#{mismatch_summary(mismatches)}"
    )

    if culprit do
      Logger.warning(
        "[piece_download] hash=#{hash_hex} index=#{state.index} corrupt_source peer=#{Peer.log_id(culprit)}"
      )

      Peer.Controller.hash_check_failed({culprit, state.hash}, state.index)
    end

    :ok
  end

  defp verdict(%State{} = state, mismatches) do
    if mismatches == [] and State.unaccounted_blocks(state) == 0, do: :received, else: :local
  end

  defp blame_label(nil), do: "none"
  defp blame_label(peer_id), do: Peer.log_id(peer_id)

  defp mismatch_summary([]), do: "none"

  defp mismatch_summary(mismatches) do
    shown =
      mismatches
      |> Enum.take(8)
      |> Enum.map_join(",", fn {begin, _length, kind} -> "#{begin}:#{kind}" end)

    extra = length(mismatches) - 8
    if extra > 0, do: "#{shown},+#{extra}", else: shown
  end

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

  # Accepted requests append to `requests` and invoke the peer callback; noop
  # paths (waiting=[], endgame redundancy cap) leave the list unchanged.
  @spec request_reply(State.t(), State.t()) :: :ok | :noop
  defp request_reply(%{requests: reqs}, %{requests: new_reqs})
       when length(new_reqs) > length(reqs),
       do: :ok

  defp request_reply(_, _), do: :noop
end

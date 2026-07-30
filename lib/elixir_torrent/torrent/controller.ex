defmodule Torrent.Controller do
  @moduledoc """
  Download pump GenServer: rarest-first piece scheduling and endgame orchestration.
  """

  use GenServer
  use Via

  import Process, only: [send_after: 3]

  require Logger

  alias Torrent.{Downloads, Model, PiecesStatistic, Superseed, Swarm}

  @next_piece_timeout 2_500
  # Concurrent in-flight pieces per torrent. Each active piece is what lets a
  # peer be busy: with only 3, a 100-seeder swarm had all but ~3 connections
  # idle. ~1 MiB piece buffers × 12 is a modest memory cost for keeping the
  # whole swarm working (libtorrent keeps dozens in flight).
  @max_parallel_pieces 12

  @doc false
  @spec effective_max_parallel(non_neg_integer()) :: pos_integer()
  def effective_max_parallel(unchoked_count)
      when is_integer(unchoked_count) and unchoked_count >= 0 do
    # Download throughput is bounded by peers that have unchoked us (each can
    # pipeline many in-flight requests). Extra piece workers only mark rare
    # pieces :processing without progressing when unchokes are scarce (typical
    # under CGNAT). Scale with unchoked slots, still cap at the nominal max.
    min(@max_parallel_pieces, max(unchoked_count * 2, 1))
  end

  # Belt-and-braces pump reconciliation. The download pump is edge-triggered by
  # block arrivals + piece completions + peer-handoff kicks; a live audit found
  # cases where all edges were missed (workers dying abnormally, peers pinned to
  # drained pieces, casts to dead workers silently swallowed) and the pump would
  # stall while peers stayed live and interested. This periodic tick is the
  # level-triggered safety net: every ~2s, if we're under-filled and have peers,
  # nudge {:next_piece, :rare}. It's cheap (single active_indices/1 call +
  # Swarm.count/1) and idempotent (the {:next_piece} handler checks capacity).
  @reconcile_interval 2_000
  # Nominal target for the fill loop after starting a piece — small delay lets
  # this piece's requests_are_dealt closure interleave with the next pick, so
  # we bring the active-pieces set up to @max_parallel_pieces without hammering.
  @post_start_pump_delay 250
  # Rate-limit "download waiting" — reconcile_pump + peer kicks can fire
  # {:next_piece} many times per second while conn=0; one line/min is enough.
  @download_waiting_log_interval_sec 60

  @spec start_link(Torrent.hash()) :: GenServer.on_start()
  def start_link(hash),
    do: GenServer.start_link(__MODULE__, hash, name: via(hash))

  @doc """
  Nudge the download scheduler immediately (e.g. after a peer handoff or have_all).
  """
  @spec kick(Torrent.hash()) :: :ok
  def kick(hash) do
    case GenServer.whereis(via(hash)) do
      nil ->
        :ok

      pid ->
        send(pid, {:next_piece, :random})
        :ok
    end
  end

  @doc false
  @spec resume_ready(Torrent.hash()) :: :ok
  def resume_ready(hash) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> send(pid, :resume_ready)
    end

    :ok
  end

  def init(hash) do
    :ok = PeerDiscovery.ensure_announce(hash)
    {:ok, hash}
  end

  def handle_info(:resume_ready, hash) do
    Logger.info(
      "[resume] controller_start hash=#{Torrent.hex_encoded_hash(hash)} scheduling download"
    )

    send_after(self(), {:next_piece, :random}, 500)
    send_after(self(), :unchoke, 1_000)
    # Kick off the periodic pump reconciler — see @reconcile_interval.
    send_after(self(), :reconcile_pump, @reconcile_interval)
    {:noreply, hash}
  end

  # Level-triggered safety net for the download request pump. Runs every
  # @reconcile_interval regardless of edges. If we're below @max_parallel_pieces
  # active pieces AND we have connected peers, post {:next_piece, :rare} —
  # the {:next_piece} handler will pick up the actual work (or no-op if the
  # world already recovered). Always reschedules itself; the timer is cheap.
  def handle_info(:reconcile_pump, hash) do
    active = Downloads.active_indices(hash)
    active_count = length(active)
    connected = Swarm.count(hash)
    unchoked = Swarm.unchoked_for_us_count(hash)
    effective_max = effective_max_parallel(unchoked)

    {active, active_count} =
      if orphan_reconcile?(connected, unchoked, active_count) do
        reconcile_idle_orphan_pieces(hash, active)
        active = Downloads.active_indices(hash)
        {active, length(active)}
      else
        {active, active_count}
      end

    reconcile_pump_kick(hash, active_count, effective_max, connected, unchoked)
    reconcile_refresh_interest(hash, active, active_count, connected)

    send_after(self(), :reconcile_pump, @reconcile_interval)
    {:noreply, hash}
  end

  def handle_info({:next_piece, strategy} = msg, hash) do
    cond do
      Model.downloaded?(hash) ->
        mark_complete(hash)

      Swarm.count(hash) > 0 ->
        next_piece(hash, strategy)

      true ->
        [downloaded, left, status] = Model.get(hash, [:downloaded, :left, :peer_status])
        connected = Swarm.count(hash)

        maybe_log_download_waiting(hash, connected, downloaded, left, status)

        Model.set_peer_status(hash, :connecting_to_peers)
        PeerDiscovery.connecting_to_peers(hash)
        send_after(self(), msg, 20_000)
    end

    {:noreply, hash}
  end

  def handle_info(:unchoke, hash) do
    send_after(self(), :reset_rank, 10_000)
    Swarm.unchoke(hash)

    {:noreply, hash}
  end

  def handle_info(:reset_rank, hash) do
    send_after(self(), :unchoke, 10_000)
    Swarm.reset_rank(hash)

    {:noreply, hash}
  end

  defp next_piece(hash, strategy) do
    active = Downloads.active_indices(hash)
    connected = Swarm.count(hash)
    unchoked = Swarm.unchoked_for_us_count(hash)
    effective_max = effective_max_parallel(unchoked)

    if length(active) >= effective_max do
      send_after(self(), {:next_piece, strategy}, 500)
    else
      pick_and_start_piece(hash, strategy, active, connected)
    end
  end

  defp pick_and_start_piece(hash, strategy, active, connected) do
    opts = [exclude: active]
    index = choice_piece_with_reconcile(hash, strategy, opts, active)

    case index do
      nil ->
        handle_no_piece_choice(hash, strategy, active, connected)

      index ->
        handle_piece_choice(hash, strategy, index, active, connected)
    end
  end

  defp choice_piece_with_reconcile(hash, strategy, opts, active) do
    case PiecesStatistic.choice_piece(hash, strategy, opts) do
      nil ->
        cleared =
          PiecesStatistic.reconcile_stale_statuses(hash, &Downloads.piece_active?(hash, &1))

        if cleared > 0 do
          Logger.debug(
            "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} reconcile_stale cleared=#{cleared} active=#{length(active)}"
          )
        end

        PiecesStatistic.choice_piece(hash, strategy, opts)

      index ->
        index
    end
  end

  defp handle_no_piece_choice(hash, strategy, active, connected) do
    Logger.debug(
      "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} strategy=#{strategy} chosen=none connected=#{connected} reason=no_available_pieces active_pieces=#{length(active)}"
    )

    if Model.downloaded?(hash) do
      mark_complete(hash)
    else
      fallback_when_no_piece(hash, active, connected)
      send_after(self(), {:next_piece, strategy}, @next_piece_timeout)
    end
  end

  defp fallback_when_no_piece(hash, active, connected) do
    if active != [] do
      index = hd(active)
      Model.set_peer_status(hash, index)
      Swarm.interested_for_piece(hash, index)
    else
      if connected > 0, do: PeerDiscovery.connecting_to_peers(hash)
      Model.set_peer_status(hash, nil)
    end
  end

  defp handle_piece_choice(hash, strategy, index, active, connected) do
    if Swarm.any_has_piece?(hash, index) or seeder_has_piece?(hash, index) do
      Logger.debug(
        "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} strategy=#{strategy} chosen=#{index} connected=#{connected} peers_have=true active_pieces=#{length(active) + 1}"
      )

      start_piece_download(hash, index, strategy)
    else
      log_availability_mismatch(hash, index, connected)

      # The statistic claimed a peer has this piece but no connected peer
      # does — the count is stale (e.g. leaked on an unclean disconnect).
      # Reset it so the picker moves on; live HAVE/bitfield traffic will
      # re-establish the real availability.
      PiecesStatistic.reset_availability(hash, index)

      Model.set_peer_status(hash, nil)
      PeerDiscovery.connecting_to_peers(hash)
      send_after(self(), {:next_piece, strategy}, @next_piece_timeout)
    end
  end

  defp reconcile_pump_kick(hash, active_count, effective_max, connected, unchoked) do
    cond do
      Model.downloaded?(hash) ->
        :noop

      active_count < effective_max and connected > 0 ->
        Logger.debug(
          "[reconcile_pump] hash=#{Torrent.hex_encoded_hash(hash)} active=#{active_count} max=#{effective_max} unchoked=#{unchoked} peers=#{connected} kick=next_piece"
        )

        send(self(), {:next_piece, :rare})

      true ->
        Logger.debug(
          "[reconcile_pump] hash=#{Torrent.hex_encoded_hash(hash)} active=#{active_count} max=#{effective_max} unchoked=#{unchoked} peers=#{connected} action=none"
        )
    end
  end

  defp reconcile_refresh_interest(hash, active, active_count, connected) do
    # Endgame (or multiple in-flight pieces): refresh interest on every active
    # index, not only Model.peer_status. A single controller status made
    # Swarm.interested_for_piece a monopoly on one piece while choked peers
    # sat pinned there with zero bytes and starved the rest (BEP-3 endgame
    # needs redundant sources on ALL remaining pieces).
    if active_count > 0 and connected > 0 and
         (Model.get(hash, :mode) == :endgame or active_count > 1) do
      Enum.each(Enum.sort(active), &Swarm.interested_for_piece(hash, &1))
    end
  end

  defp start_piece_download(hash, index, strategy) do
    pid = self()

    Downloads.piece(
      hash,
      index,
      fn -> piece_completed(hash, index) end,
      fn -> send(pid, {:next_piece, :rare}) end
    )

    Model.set_peer_status(hash, index)
    Swarm.interested_for_piece(hash, index)

    # Immediately reschedule the pump so we drive active_indices up to the
    # effective parallel cap without waiting for this piece's requests_are_dealt
    # closure to fire (that closure only wakes on the last subpiece being handed
    # out, which never happens if the peer stalls). A small delay lets the just-
    # started piece begin taking requests before we contend again.
    send_after(self(), {:next_piece, strategy}, @post_start_pump_delay)
  end

  defp seeder_has_piece?(hash, index) do
    PiecesStatistic.availability(hash, index) > 0 and
      Enum.any?(Swarm.peer_supervisors(hash), &peer_offers_piece?(&1, index))
  end

  defp peer_offers_piece?(pid, index) do
    case Peer.get_key(pid) do
      key when is_tuple(key) -> safe_peer_has_piece?(key, index)
      _ -> false
    end
  end

  defp safe_peer_has_piece?(key, index) do
    Peer.Controller.has_all?(key) or Peer.Controller.has_index?(key, index)
  catch
    :exit, _ -> false
  end

  defp mark_complete(hash) do
    Model.set_peer_status(hash, :seed)
    Superseed.activate(hash, Swarm.confirmed_seed_count(hash))
    Swarm.seed(hash)
    Downloads.stop(hash)
  end

  defp piece_completed(hash, index) do
    [count] = Torrent.get(hash, [:pieces_count])

    # This callback only runs for a piece completed from the live peer download
    # path, never for startup resume verification. Entering here prevents a
    # long-complete torrent from being mistaken for a new initial seed.
    if Enum.all?(0..(count - 1), &(PiecesStatistic.get_status(hash, &1) == :complete)) do
      Superseed.arm(hash)
    else
      Swarm.have(hash, index)
    end
  end

  defp log_availability_mismatch(hash, index, connected) do
    seeder_count =
      hash
      |> Swarm.peer_supervisors()
      |> Enum.count(fn pid ->
        case Peer.get_key(pid) do
          key when is_tuple(key) -> safe_peer_has_all?(key)
          _ -> false
        end
      end)

    Logger.warning(
      "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} chosen=#{index} connected=#{connected} peers_have=false seeders=#{seeder_count} stat=#{PiecesStatistic.availability(hash, index)}"
    )
  end

  defp safe_peer_has_all?(key) do
    Peer.Controller.has_all?(key)
  catch
    :exit, _ -> false
  end

  # Level-triggered backstop when the swarm cannot deliver blocks (conn=0) or
  # nobody has unchoked us yet (unchoked=0). Idle piece workers — requests=[]
  # because peers dropped before request/3 — otherwise pin active=1 and freeze
  # the pump until the 100s stall timer (now 10s orphan probe, but reconcile
  # is the fast path on reconnect).
  defp orphan_reconcile?(connected, unchoked, active_count) do
    active_count > 0 and (connected == 0 or unchoked == 0)
  end

  defp reconcile_idle_orphan_pieces(hash, active) do
    active
    |> Enum.reject(&Downloads.piece_has_in_flight?(hash, &1))
    |> Enum.each(&Downloads.abort_idle_piece(hash, &1, force: true))
  end

  defp maybe_log_download_waiting(hash, connected, downloaded, left, status) do
    key = {:download_waiting_logged, hash}
    now = System.monotonic_time(:second)
    last = Process.get(key, 0)

    if now - last >= @download_waiting_log_interval_sec do
      Logger.debug(
        "download waiting hash=#{Torrent.hex_encoded_hash(hash)} connected=#{connected} downloaded=#{downloaded} left=#{left} status=#{inspect(status)}"
      )

      Process.put(key, now)
    end
  end
end

defmodule Peer.ConnectionManager do
  @moduledoc false

  use GenServer
  use Via

  import Process, only: [send_after: 3]

  require Logger

  alias Peer.ConnectionManager.Queue, as: DialQueue
  alias Torrent.Swarm

  # @target_connected must stay strictly below @swarm_cap. Both `handle_info(:tick)`
  # and `handle_info({:dial_done, ...})` gate peer-refresh/replenish on
  # `connected < @target_connected`; if target ≥ cap those branches fire every
  # single tick (since connected can never exceed cap), turning "keep the swarm
  # topped up" into "hammer the trackers/DHT forever". Target=50 gives a small
  # hysteresis band 50..60 where we stop asking for more candidates.
  @target_connected 50
  @swarm_cap 60
  @default_batch 40
  @escalated_batch 50
  @normal_interval_ms 3_000
  @escalated_interval_ms 1_000
  @low_speed_bytes_per_sec 32_768
  @low_connected_threshold 12
  @evict_batch 5
  @snub_evict_batch 2
  # At most one snub batch per interval — avoids churning seeders that just
  # connected and have not yet unchoked / delivered their first block.
  @snub_min_interval_ms 10_000
  @zero_upload_grace_ms 60_000
  @useless_grace_ms 30_000
  @snub_grace_ms 60_000
  # Unchoked but no block data for this long → snub (libtorrent-style). Shorter
  # than @snub_grace_ms so we drop stallers before the wall-clock zero-byte path.
  @idle_unchoked_snub_ms 30_000

  def start_link(hash) do
    GenServer.start_link(__MODULE__, hash, name: via(hash))
  end

  @spec offer_peers(Torrent.hash(), [Peer.t()]) :: :ok
  def offer_peers(hash, peers) when is_list(peers) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:offer, peers, :discovery})
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec offer_peers_from_pex(Torrent.hash(), binary(), [Peer.t()]) :: :ok
  def offer_peers_from_pex(hash, pex_source, peers)
      when is_binary(hash) and byte_size(hash) == 20 and is_list(peers) and
             is_binary(pex_source) and byte_size(pex_source) == 20 do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:offer_pex, pex_source, peers})
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec revoke_pex_peers(Torrent.hash(), binary(), [Peer.t()]) :: :ok
  def revoke_pex_peers(hash, pex_source, dropped)
      when is_binary(hash) and byte_size(hash) == 20 and is_list(dropped) and
             is_binary(pex_source) and byte_size(pex_source) == 20 do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:revoke_pex, pex_source, dropped})
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec apply_pex_delta(Torrent.hash(), binary(), [Peer.t()], [Peer.t()]) :: :ok
  def apply_pex_delta(hash, pex_source, added, dropped)
      when is_binary(hash) and byte_size(hash) == 20 and is_list(added) and is_list(dropped) and
             is_binary(pex_source) and byte_size(pex_source) == 20 do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:pex_delta, pex_source, added, dropped})
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec prioritize_dial_queue(Torrent.hash(), [Peer.t()]) :: [Peer.t()]
  def prioritize_dial_queue(hash, peers) when is_list(peers) do
    # Order: productive (delivered bytes this session) → BEP 11 PEX seed bit →
    # rest. Queue is a Map keyed by `{ip,port}` so iteration order is undefined;
    # scarce outbound dial slots (CGNAT ~1.3% v4) must hit known-good endpoints
    # and likely seeders before random leechers from merged offer batches.
    Enum.sort_by(peers, fn %Peer{ip: ip, port: port, seed: seed} ->
      {not Peer.DialBackoff.productive?(hash, ip, port), seed != true}
    end)
  end

  @spec kick(Torrent.hash()) :: :ok
  def kick(hash) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, :dial_now)
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(hash) do
    send_after(self(), :tick, @normal_interval_ms)
    # nil = never snubbed; monotonic ms can be negative so 0 is not a safe sentinel.
    {:ok, %{hash: hash, queue: %{}, dialing?: false, last_snub_ms: nil}}
  end

  @impl true
  def handle_cast({:offer, peers, source}, state) when is_list(peers) do
    queue = DialQueue.offer(state.queue, peers, source)
    maybe_continue_dial(state, queue, peers != [])
  end

  def handle_cast({:offer_pex, pex_source, peers}, state) when is_list(peers) do
    queue = DialQueue.offer(state.queue, peers, {:pex, pex_source})
    maybe_continue_dial(state, queue, peers != [])
  end

  def handle_cast({:revoke_pex, pex_source, dropped}, state) when is_list(dropped) do
    queue = DialQueue.revoke_pex(state.queue, pex_source, dropped)
    {:noreply, %{state | queue: queue}}
  end

  def handle_cast({:pex_delta, pex_source, added, dropped}, state) do
    # One mailbox operation prevents handle_continue(:dial) from selecting a
    # just-dropped endpoint between separate offer/revoke casts.
    queue =
      state.queue
      |> DialQueue.revoke_pex(pex_source, dropped)
      |> DialQueue.offer(added, {:pex, pex_source})

    maybe_continue_dial(state, queue, added != [])
  end

  def handle_cast(:dial_now, state) do
    {:noreply, state, {:continue, :dial}}
  end

  @impl true
  def handle_continue(:dial, %{dialing?: true} = state), do: {:noreply, state}

  def handle_continue(:dial, %{hash: hash} = state) do
    # Single Swarm.count/1 per entry point — was called 4× per tick when the
    # queue was non-empty (via tick_interval → escalate?, via batch_size →
    # escalate?, plus the direct check here). Now hoisted and threaded through.
    connected = Swarm.count(hash)
    maybe_dial(state, connected)
  end

  @impl true
  def handle_info(:tick, %{hash: hash} = state) do
    connected = Swarm.count(hash)
    send_after(self(), :tick, tick_interval(hash, connected))

    cond do
      connected >= @swarm_cap and low_download_speed?(hash) and downloading?(hash) ->
        {evicted, reason} = evict_stale_peers(hash, connected)

        if evicted > 0 do
          Logger.info(
            "[peer_evict] hash=#{Torrent.hex_encoded_hash(hash)} n=#{evicted} reason=#{reason}"
          )
        end

        connected = Swarm.count(hash)
        maybe_replenish_discovery(state, connected)
        maybe_dial_or_noreply(state, connected)

      connected >= @swarm_cap ->
        {:noreply, state}

      low_download_speed?(hash) and downloading?(hash) and connected >= @low_connected_threshold ->
        now = System.monotonic_time(:millisecond)

        state =
          if is_nil(state.last_snub_ms) or now - state.last_snub_ms >= @snub_min_interval_ms do
            evicted = evict_snub_peers(hash, connected)

            if evicted > 0 do
              Logger.info("[peer_snub] hash=#{Torrent.hex_encoded_hash(hash)} n=#{evicted}")

              %{state | last_snub_ms: now}
            else
              state
            end
          else
            state
          end

        connected = Swarm.count(hash)
        maybe_replenish_discovery(state, connected)
        maybe_dial_or_noreply(state, connected)

      true ->
        maybe_replenish_discovery(state, connected)
        maybe_dial_or_noreply(state, connected)
    end
  end

  @impl true
  def handle_info({:dial_done, selected_keys, results}, %{hash: hash} = state) do
    {_ok, _failures, failed_peers} = results
    failed_keys = MapSet.new(Enum.map(failed_peers, fn {p, _} -> {p.ip, p.port} end))

    keys_to_drop = Enum.reject(selected_keys, &MapSet.member?(failed_keys, &1))
    queue = Map.drop(state.queue, keys_to_drop)
    connected = Swarm.count(hash)
    record_failures(hash, results, connected)

    state = %{state | queue: queue, dialing?: false}
    maybe_replenish_discovery(state, connected)

    maybe_dial(state, connected)
  end

  defp maybe_continue_dial(state, queue, continue?) do
    if continue? do
      {:noreply, %{state | queue: queue}, {:continue, :dial}}
    else
      {:noreply, %{state | queue: queue}}
    end
  end

  defp maybe_dial(%{dialing?: true} = state, _connected), do: {:noreply, state}
  defp maybe_dial(state, connected) when connected >= @swarm_cap, do: {:noreply, state}

  defp maybe_dial(%{hash: hash} = state, connected) do
    dial_batch(state, batch_size(hash, connected))
  end

  defp maybe_dial_or_noreply(state, connected) do
    if map_size(state.queue) > 0 do
      maybe_dial(state, connected)
    else
      {:noreply, state}
    end
  end

  defp dial_batch(%{hash: hash, queue: queue} = state, batch) do
    peers =
      hash
      |> prioritize_dial_queue(DialQueue.peers(queue))
      |> Acceptor.Connection.Handshakes.select_peers_to_dial(hash, batch)

    if peers == [] do
      if map_size(queue) == 0 do
        PeerDiscovery.Announce.replenish_candidates(hash)
      end

      {:noreply, state}
    else
      selected_keys = Enum.map(peers, fn p -> {p.ip, p.port} end)
      parent = self()

      Task.start(fn ->
        results = Acceptor.Connection.Handshakes.dial_peers(peers, hash)
        send(parent, {:dial_done, selected_keys, results})
      end)

      {:noreply, %{state | dialing?: true}}
    end
  end

  defp record_failures(hash, {ok_count, failures, failed_peers}, connected) do
    Enum.each(failed_peers, fn {peer, reason} ->
      Peer.DialBackoff.record(hash, peer.ip, peer.port, reason)

      # Handoff failure means the endpoint completed the BT handshake — NAT punch
      # would target an already reachable host; genuine connect/handshake fails still punch.
      unless reason == :socket_handoff_failed do
        Peer.Holepunch.maybe_request(hash, peer, reason)
      end
    end)

    if ok_count > 0 or map_size(failures) > 0 do
      Logger.debug(
        "[peer_dial] manager hash=#{Torrent.hex_encoded_hash(hash)} ok=#{ok_count} failed=#{inspect(failures)} connected=#{connected}"
      )
    end
  end

  defp batch_size(hash, connected) do
    if escalate?(hash, connected), do: @escalated_batch, else: @default_batch
  end

  defp tick_interval(hash, connected) do
    if escalate?(hash, connected), do: @escalated_interval_ms, else: @normal_interval_ms
  end

  defp escalate?(hash, connected) do
    cond do
      connected >= @target_connected -> false
      connected < @low_connected_threshold -> true
      low_download_speed?(hash) and connected < div(@target_connected, 2) -> true
      # Under CGNAT, connected count ≠ useful unchoked seeders: many peers can be
      # choke-cycling without delivering bytes. When throughput is dead but we still
      # have headroom below @target_connected, keep requesting fresh candidates even
      # above the soft div(target,2)=25 band (e.g. 31 connected at ~0 B/s).
      low_download_speed?(hash) and connected < @target_connected -> true
      true -> false
    end
  end

  # Push discovery to hand us fresh candidates. Two mechanisms:
  #   * `request_peer_refresh` triggers a fresh tracker/DHT hit inside Announce,
  #     naturally rate-limited to ~30s per @under_target_announce_sec — safe to
  #     call unconditionally under target.
  #   * `replenish_candidates` re-emits Announce's already-cached peer list back
  #     to us via `offer_peers` (cheap `Map.put` per peer into our queue) — good
  #     for the case where we've already dialed everything we know about.
  #
  # Under escalation we do BOTH on every tick / dial_done — the old code only
  # requested a refresh when our queue was empty, and only replenished from cache
  # when the queue fell below @default_batch. That left a torrent stuck below
  # target dialling the same ~40 candidates repeatedly instead of asking for
  # more. Baseline (non-escalate) behaviour is preserved: idle-queue → refresh,
  # low queue → replenish.
  defp maybe_replenish_discovery(%{hash: hash, queue: queue}, connected) do
    cond do
      connected >= @target_connected ->
        :ok

      escalate?(hash, connected) ->
        PeerDiscovery.Announce.request_peer_refresh(hash)
        PeerDiscovery.Announce.replenish_candidates(hash)
        :ok

      map_size(queue) == 0 ->
        PeerDiscovery.Announce.request_peer_refresh(hash)
        :ok

      map_size(queue) < @default_batch ->
        PeerDiscovery.Announce.replenish_candidates(hash)
        :ok

      true ->
        :ok
    end
  end

  defp low_download_speed?(hash) do
    case Torrent.get(hash, :speed) do
      %{download: speed} when is_integer(speed) -> speed < @low_speed_bytes_per_sec
      _ -> true
    end
  catch
    _ -> true
  end

  # Never evict download-usefulness peers on completed torrents — seeding slots
  # are upload relationships, not leech throughput.
  defp downloading?(hash) do
    case Torrent.get(hash, [:peer_status, :left]) do
      [status, left] when status != :seed and is_integer(left) and left > 0 -> true
      _ -> false
    end
  catch
    _ -> false
  end

  # Below swarm cap but above the micro-swarm floor: drop a few peers that have
  # delivered zero bytes for @snub_grace_ms wall-clock time to free dial slots
  # without waiting for the hard @swarm_cap freeze (common at 30–50 connected
  # under CGNAT). Do not require choke_me?: optimistic unchoke cycles every 1–3s
  # reset choke_me before grace expires; zero-byte age is the real snub signal.
  defp evict_snub_peers(hash, connected) do
    candidates =
      hash
      |> Swarm.peer_supervisors()
      |> Enum.flat_map(&peer_eviction_candidate/1)

    pids = select_snub_eviction_pids(candidates, connected)

    if pids == [] do
      0
    else
      :ok = Swarm.evict_peers(hash, pids)
      length(pids)
    end
  end

  defp select_snub_eviction_pids(candidates, connected) do
    candidates
    |> Enum.filter(&snub_eligible?/1)
    |> Enum.sort_by(fn {_pid, info} -> eviction_sort_key(info) end)
    |> Enum.reduce({[], connected}, fn {pid, _info}, {acc, remaining} ->
      if length(acc) < @snub_evict_batch and remaining - 1 >= @low_connected_threshold do
        {[pid | acc], remaining - 1}
      else
        {acc, remaining}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp snub_eligible?({_pid, info}) do
    not snub_exempt?(info) and (zero_byte_snub?(info) or idle_unchoked_snub?(info))
  end

  # Seeders with overlapping usefulness (bitfield :all) may show zero downloaded_bytes
  # until the first unchoke/block — snubbing them frees dial slots we need them for.
  defp snub_exempt?(%{useful?: true, seeder?: true}), do: true
  defp snub_exempt?(_), do: false

  # Wall-clock zero-byte snub: connected long enough but never delivered.
  defp zero_byte_snub?(info) do
    info.downloaded_bytes == 0 and info.age_ms >= @snub_grace_ms
  end

  # Idle-while-unchoked: peer unchoked us but sent no blocks recently. Catches
  # optimistic-unchoke cycles that reset choke_me before @snub_grace_ms expires.
  defp idle_unchoked_snub?(info) do
    not info.choke_me? and
      info.idle_ms >= @idle_unchoked_snub_ms and
      info.age_ms >= @idle_unchoked_snub_ms
  end

  # At swarm cap with dead throughput, disconnect choke-cycling / zero-overlap
  # peers so ConnectionManager can dial fresh seeders (critical under CGNAT where
  # cap freeze previously blocked all discovery).
  defp evict_stale_peers(hash, connected) do
    candidates =
      hash
      |> Swarm.peer_supervisors()
      |> Enum.flat_map(&peer_eviction_candidate/1)

    pids = select_eviction_pids(candidates, connected)

    if pids == [] do
      {0, nil}
    else
      reason = eviction_log_reason(candidates, pids)
      :ok = Swarm.evict_peers(hash, pids)
      {length(pids), reason}
    end
  end

  defp peer_eviction_candidate(pid) do
    with key when is_tuple(key) <- Peer.get_key(pid),
         info when is_map(info) <- Peer.Controller.eviction_info(key) do
      [{pid, info}]
    else
      _ -> []
    end
  end

  defp select_eviction_pids(candidates, connected) do
    candidates
    |> Enum.filter(&eviction_eligible?/1)
    |> Enum.sort_by(fn {_pid, info} -> eviction_sort_key(info) end)
    |> Enum.reduce({[], connected}, fn {pid, info}, {acc, remaining} ->
      if length(acc) < @evict_batch and may_evict?(info, remaining) do
        {[pid | acc], remaining - 1}
      else
        {acc, remaining}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp eviction_eligible?({_pid, info}) do
    (info.downloaded_bytes == 0 and info.age_ms >= @zero_upload_grace_ms) or
      (info.useful? == false and info.age_ms >= @useless_grace_ms)
  end

  # Prefer choked peers (not delivering) and oldest connections first.
  defp eviction_sort_key(info) do
    choke_rank = if info.choke_me?, do: 0, else: 1
    {choke_rank, -info.age_ms}
  end

  # Keep at least @low_connected_threshold peers unless they are provably useless
  # (no overlapping missing pieces) — useless evictions may drop below the floor.
  defp may_evict?(info, remaining_connected) do
    info.useful? == false or remaining_connected - 1 >= @low_connected_threshold
  end

  defp eviction_log_reason(candidates, evicted_pids) do
    evicted = MapSet.new(evicted_pids)

    candidates
    |> Enum.filter(fn {pid, _} -> MapSet.member?(evicted, pid) end)
    |> Enum.map(fn {_pid, info} -> eviction_reason_label(info) end)
    |> Enum.frequencies()
    |> Enum.map_join(",", fn {reason, count} -> "#{reason}:#{count}" end)
  end

  defp eviction_reason_label(%{downloaded_bytes: 0, useful?: false}), do: "useless"

  defp eviction_reason_label(%{downloaded_bytes: 0}), do: "zero_upload"

  defp eviction_reason_label(_), do: "useless"
end

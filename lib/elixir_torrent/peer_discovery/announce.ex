defmodule PeerDiscovery.Announce do
  @enforce_keys [:torrent_pid, :hash]
  defstruct torrent_pid: nil,
            hash: nil,
            dht_hashes: [],
            dht_module: DHT,
            tiers: [],
            tier_index: 0,
            requests: %{},
            peers: %{},
            dht_peers: [],
            dht_round_peers: [],
            # BEP 9 § Magnet URI format — x.pe endpoints handed off from Magnet.Fetcher
            # via PeerDiscovery.SeedPeers. Merged into the peer pool alongside tracker
            # and DHT peers so magnet-supplied hints keep being tried across the whole
            # torrent session, not only during metadata retrieval.
            seed_peers: [],
            private?: false,
            # Under swarm target, up to @under_target_tier_fanout tiers announce concurrently
            # (tier_index => in-flight tracker Task count). At/over target only one tier key
            # is present — BEP tier preference preserved when the swarm is healthy.
            tier_batches: %{},
            # Highest tier index started in the current under-target fan-out wave; used to
            # pick the next wave start after all batches complete with no peers.
            fanout_high_tier: nil,
            pex_snapshot: %{},
            last_tracker_announce_ms: nil,
            last_dht_lookup_ms: nil,
            tracker_interval_sec: nil,
            tracker_min_interval_sec: nil,
            disabled: MapSet.new(),
            # BEP 31 cooldowns are per announce URL. Values are monotonic
            # millisecond deadlines so one overloaded tracker can sit out
            # without delaying healthy siblings in the same tier.
            retry_after_ms: %{},
            # BEP 48 § Scrape convention — cached per-tracker swarm health used to skip
            # dead-swarm trackers at announce time. Keyed by announce URL.
            # %{url => %{seeders: n, leechers: n, completed: n, ts_ms: mono_ms}}
            scrape_stats: %{},
            last_scrape_ms: nil

  use GenServer
  use Via

  import Process, only: [send_after: 3]

  alias PeerDiscovery.Requests
  alias Torrent.{Model, Swarm}
  require Logger

  @pex_interval_ms 60_000
  @swarm_target_peers 80
  # Under acute peer starvation (CGNAT), black-hole tier-0 UDP (rarbg.to ~15 s) must
  # not serialize the whole announce-list — fan out a small window of tiers like
  # libtorrent under load. BEP tier order is a preference, not a hard mutex when
  # Swarm.count < target; peer connection pressure applies to dials, not trackers.
  @under_target_tier_fanout 4
  @announce_floor_sec 30
  @under_target_announce_sec 30
  @dht_floor_sec 30
  @dht_interval_sec 300
  # BEP 5 § DHT — under acute peer pressure, re-lookup twice as often as the
  # normal under-target cadence. Threshold mirrors Peer.ConnectionManager's
  # escalation trigger, so DHT ramps up on the same torrents ConnectionManager
  # is already burning 1 s ticks on.
  @dht_critical_threshold 12
  @dht_critical_sec 15
  @peer_refresh_tick_ms 30_000
  # BEP 48 § Scrape convention — refresh cadence for tracker health checks.
  # 5 min mirrors libtorrent's ~5-min default; short enough to react to trackers
  # coming back online, long enough that scraping N trackers per torrent is cheap.
  @scrape_interval_ms 5 * 60 * 1_000
  # Initial delay before first scrape tick — let the first parallel announce
  # settle (so we don't scrape and announce a tracker back-to-back).
  @scrape_initial_delay_ms 45_000
  # Trust a scrape result as "swarm is dead" only if we heard {0,0} within this
  # window. Older data is stale — network conditions or the tracker itself may
  # have changed. Slightly longer than one scrape cycle so a single failed scrape
  # doesn't unblock announcing a known-dead tracker.
  @scrape_ttl_ms 20 * 60 * 1_000

  def start_link([_pid, torrent] = args) do
    GenServer.start_link(__MODULE__, args, name: via(torrent.hash))
  end

  @doc false
  def name(hash), do: via(hash)

  def get(hash),
    do: GenServer.call(via(hash), :get)

  @doc """
  Whether the torrent identified by `hash` is marked private per BEP 27.
  Returns `false` if the Announce process is not alive; the caller should
  check the Registry first if that distinction matters.
  """
  @spec private?(Torrent.hash()) :: boolean()
  def private?(hash) do
    GenServer.call(via(hash), :private?)
  catch
    :exit, _ -> false
  end

  @doc false
  @spec peer_list(%__MODULE__{}) :: [Peer.t()]
  def peer_list(%__MODULE__{} = state), do: merged_peers(state)

  def connecting_to_peers(hash) do
    _ignored = PeerDiscovery.ensure_announce(hash)
    GenServer.cast(via(hash), :connecting_to_peers)
  end

  @doc false
  @spec request_peer_refresh(Torrent.hash()) :: :ok
  def request_peer_refresh(hash) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, :maybe_refresh_peers)
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec replenish_candidates(Torrent.hash()) :: :ok
  def replenish_candidates(hash) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, :replenish_candidates)
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec tracker_announce_allowed?(%__MODULE__{}, non_neg_integer()) ::
          :ok | {:wait, non_neg_integer()}
  def tracker_announce_allowed?(%__MODULE__{} = state, now_ms) do
    # Under target with no tracker peers yet, do not apply the 30 s floor across
    # tiers — an empty announce on tier N (rarbg.to → peers=[]) must not block
    # tier N+1 (opentrackr). BEP min-interval still applies once a tracker yields
    # peers (see apply_tracker_response/5).
    if starved_with_no_tracker_peers?(state) do
      :ok
    else
      min_sec = state.tracker_min_interval_sec || @announce_floor_sec
      interval_sec = tracker_announce_interval_sec(state)
      required_ms = max(min_sec, interval_sec) * 1_000

      case state.last_tracker_announce_ms do
        nil ->
          :ok

        last when now_ms - last >= required_ms ->
          :ok

        last ->
          {:wait, required_ms - (now_ms - last)}
      end
    end
  end

  @doc false
  @spec dht_lookup_allowed?(%__MODULE__{}, non_neg_integer()) :: :ok | {:wait, non_neg_integer()}
  def dht_lookup_allowed?(%__MODULE__{} = state, now_ms) do
    interval_sec = dht_lookup_interval_sec(state)
    required_ms = interval_sec * 1_000

    case state.last_dht_lookup_ms do
      nil ->
        :ok

      last when now_ms - last >= required_ms ->
        :ok

      last ->
        {:wait, required_ms - (now_ms - last)}
    end
  end

  @doc false
  @spec dead_tier_advance_interval(%__MODULE__{}, non_neg_integer()) :: non_neg_integer()
  def dead_tier_advance_interval(%__MODULE__{} = state, tier_index),
    do: dead_tier_advance_sec(state, tier_index)

  @doc false
  @spec parallel_tier_reschedule_interval(%__MODULE__{}, non_neg_integer()) ::
          non_neg_integer()
  def parallel_tier_reschedule_interval(%__MODULE__{} = state, fallback_sec),
    do: parallel_tier_reschedule_sec(state, fallback_sec)

  @doc false
  @spec parallel_tier_failure_advance_interval(
          %__MODULE__{},
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  def parallel_tier_failure_advance_interval(%__MODULE__{} = state, tier_index, fallback_sec),
    do: parallel_tier_failure_advance_sec(state, tier_index, fallback_sec)

  @doc false
  @spec tracker_request_opts(%__MODULE__{}) :: Tracker.request_opts()
  def tracker_request_opts(%__MODULE__{} = state), do: tracker_request_opts_for(state)

  @doc false
  @spec resolve_announcable_tier_index(%__MODULE__{}, non_neg_integer()) ::
          {non_neg_integer(), :live | :ring_exhausted}
  def resolve_announcable_tier_index(%__MODULE__{} = state, start_index) do
    {_state, tier_index, status} = resolve_announcable_tier(state, start_index)
    {tier_index, status}
  end

  @doc false
  @spec under_target_tier_fanout() :: pos_integer()
  def under_target_tier_fanout(), do: @under_target_tier_fanout

  @doc false
  @spec tier_batches_active?(%__MODULE__{}) :: boolean()
  def tier_batches_active?(%__MODULE__{tier_batches: batches}), do: map_size(batches) > 0

  @doc false
  @spec tracker_peers_empty?(%__MODULE__{}) :: boolean()
  def tracker_peers_empty?(%__MODULE__{peers: peers}) do
    peers |> Map.values() |> List.flatten() == []
  end

  @doc false
  @spec dispatch_task_message(%__MODULE__{}, term()) :: %__MODULE__{}
  def dispatch_task_message(%__MODULE__{} = state, message) do
    case handle_info(message, state) do
      {:noreply, new_state} -> new_state
      {:stop, _, new_state} -> new_state
    end
  end

  @doc false
  @spec apply_pex_snapshot(%__MODULE__{}, %{Peer.UtPex.endpoint() => Peer.UtPex.Entry.t()}) ::
          %__MODULE__{}
  def apply_pex_snapshot(%__MODULE__{} = state, current) when is_map(current) do
    apply_pex_snapshot_delta(state, current)
  end

  @doc false
  @spec pop_request(%__MODULE__{}, reference()) :: {term(), %__MODULE__{}}
  def pop_request(%__MODULE__{requests: requests} = state, ref) do
    {meta, requests} = Map.pop(requests, ref)
    {meta, %{state | requests: requests}}
  end

  @spec stopped_announce(Torrent.hash()) :: :ok
  def stopped_announce(hash) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.call(pid, :stopped_announce, 15_000)
    end
  catch
    :exit, _ -> :ok
  end

  def init([pid, torrent]), do: init([pid, torrent, []])

  def init([pid, torrent, opts]) do
    Process.monitor(pid)

    tiers = extract_tiers(torrent.metadata)
    bootstrap_torrent_nodes(torrent.metadata)
    seed_peers = PeerDiscovery.SeedPeers.take(torrent.hash)

    state = %__MODULE__{
      torrent_pid: pid,
      hash: torrent.hash,
      dht_hashes: Torrent.discovery_swarm_hashes(torrent),
      dht_module: Keyword.get(opts, :dht_module, DHT),
      tiers: tiers,
      private?: Torrent.private?(torrent),
      pex_snapshot: %{},
      seed_peers: seed_peers
    }

    if seed_peers != [] do
      Logger.info(
        "[peer_discovery] seed_peers_loaded hash=#{Torrent.hex_encoded_hash(torrent.hash)} count=#{length(seed_peers)}"
      )

      send(self(), :offer_seed_peers)
    end

    cond do
      tiers != [] ->
        {state, first_tier, first_status} = resolve_announcable_tier(state, 0)

        Logger.info(
          "[peer_discovery] first_announce_scheduled hash=#{Torrent.hex_encoded_hash(torrent.hash)} tier=#{first_tier} trackers=#{length(Enum.at(tiers, first_tier) || [])}"
        )

        if first_status == :live do
          send(self(), {:parallel_announce, first_tier})
        end

        if dht_allowed?(state) do
          send(self(), :dht_lookup)
        end

      dht_allowed?(state) ->
        Logger.info(
          "[peer_discovery] first_announce_scheduled hash=#{Torrent.hex_encoded_hash(torrent.hash)} tier=none dht_only=true"
        )

        send(self(), :dht_lookup)

      true ->
        :ok
    end

    if pex_allowed?(state), do: schedule_pex(self(), @pex_interval_ms)
    send_after(self(), :peer_refresh_tick, @peer_refresh_tick_ms)

    if tiers != [] do
      send_after(self(), :scrape_tick, @scrape_initial_delay_ms)
    end

    {:ok, state}
  end

  def handle_call(:get, _, state),
    do: {:reply, merged_peers(state), state}

  def handle_call(:private?, _, %__MODULE__{private?: private?} = state),
    do: {:reply, private?, state}

  def handle_call(:stopped_announce, _, %__MODULE__{hash: hash, tiers: tiers} = state) do
    tiers
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.each(fn announce ->
      _ = Tracker.request!(announce, hash)
    end)

    {:reply, :ok, state}
  end

  def handle_cast(:connecting_to_peers, state) do
    peer_list = merged_peers(state)
    tracker_count = state.peers |> Map.values() |> List.flatten() |> length()
    dht_count = length(state.dht_peers)

    Logger.debug(
      "[peer_dial] hash=#{Torrent.hex_encoded_hash(state.hash)} discovered=#{length(peer_list)} tracker=#{tracker_count} dht=#{dht_count} connected=#{Swarm.count(state.hash)}"
    )

    :ok = Peer.ConnectionManager.offer_peers(state.hash, peer_list)
    Peer.ConnectionManager.kick(state.hash)
    {:noreply, state}
  end

  def handle_cast(:maybe_refresh_peers, state) do
    {:noreply, maybe_refresh_under_target(state)}
  end

  def handle_cast(:replenish_candidates, state) do
    peers = merged_peers(state)

    if peers != [] do
      :ok = Peer.ConnectionManager.offer_peers(state.hash, peers)
      Peer.ConnectionManager.kick(state.hash)
    end

    {:noreply, state}
  end

  def handle_info(:peer_refresh_tick, state) do
    send_after(self(), :peer_refresh_tick, @peer_refresh_tick_ms)
    {:noreply, maybe_refresh_under_target(state)}
  end

  def handle_info(:offer_seed_peers, %__MODULE__{hash: hash} = state) do
    peers = merged_peers(state)

    if peers != [] do
      :ok = Peer.ConnectionManager.offer_peers(hash, peers)
      Peer.ConnectionManager.kick(hash)
    end

    {:noreply, state}
  end

  def handle_info({:parallel_announce, start_tier}, %__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    case tracker_announce_allowed?(state, now) do
      {:wait, delay_ms} ->
        send_after(self(), {:parallel_announce, start_tier}, delay_ms)
        {:noreply, state}

      :ok ->
        if Swarm.count(state.hash) >= @swarm_target_peers do
          {:noreply, handle_at_target_tier_announce(state, start_tier)}
        else
          handle_under_target_tier_fanout(state, start_tier)
        end
    end
  end

  def handle_info(:pex_broadcast, state) do
    state = maybe_broadcast_pex(state)
    if pex_allowed?(state), do: schedule_pex(self(), @pex_interval_ms)
    {:noreply, state}
  end

  def handle_info({ref, %Tracker.Response{} = response}, state) do
    case Map.pop(state.requests, ref) do
      {nil, _} ->
        {:noreply, state}

      {{announce, tier_index, tracker_index}, requests} ->
        state = apply_tracker_response(state, announce, tier_index, tracker_index, response)
        state = dec_tier_batch(state, tier_index)
        {:noreply, %{state | requests: requests}}
    end
  end

  def handle_info(:dht_lookup, %__MODULE__{} = state) do
    cond do
      not dht_allowed?(state) ->
        {:noreply, state}

      dht_request_pending?(state) ->
        {:noreply, state}

      true ->
        now = System.monotonic_time(:millisecond)

        case dht_lookup_allowed?(state, now) do
          {:wait, delay_ms} ->
            send_after(self(), :dht_lookup, delay_ms)
            {:noreply, state}

          :ok ->
            dht_module = state.dht_module

            state =
              Enum.reduce(dht_hashes(state), %{state | dht_round_peers: []}, fn dht_hash, acc ->
                %Task{ref: ref} =
                  Task.Supervisor.async_nolink(Requests, dht_module, :get_peers, [dht_hash])

                put_in(acc, [Access.key!(:requests), ref], {:dht, dht_hash})
              end)

            {:noreply, %{state | last_dht_lookup_ms: now}}
        end
    end
  end

  def handle_info({ref, {:ok, peer_list}}, state) when is_list(peer_list) do
    {request, state} = pop_request(state, ref)

    case request do
      {:dht, _dht_hash} ->
        state = merge_dht_round_peers(state, peer_list)
        maybe_handshake_dht_peers(state, peer_list)
        {:noreply, maybe_finish_dht_round(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:scrape_tick, %__MODULE__{} = state) do
    send_after(self(), :scrape_tick, @scrape_interval_ms)
    {:noreply, start_scrapes(state)}
  end

  # BEP 48 scrape success — cache {seeders, leechers, completed} against the
  # announce URL. Used later in start_parallel_tier/3 to skip trackers whose
  # swarm is empty (0/0) so we don't burn a full-tier parallel announce on
  # a dead swarm every 30 s while under target.
  def handle_info({ref, %{seeders: _, leechers: _, completed: _} = stats}, state) do
    case pop_request(state, ref) do
      {{:scrape, announce}, state} ->
        now = System.monotonic_time(:millisecond)

        Logger.debug(
          "[tracker_scrape] ok hash=#{Torrent.hex_encoded_hash(state.hash)} tracker=#{announce} seeders=#{stats.seeders} leechers=#{stats.leechers} completed=#{stats.completed}"
        )

        entry = Map.put(stats, :ts_ms, now)
        {:noreply, put_in(state.scrape_stats[announce], entry)}

      {_, _} ->
        {:noreply, state}
    end
  end

  def handle_info({ref, {:error, _reason}}, state) do
    {request, state} = pop_request(state, ref)

    case request do
      {:dht, _dht_hash} ->
        {:noreply, maybe_finish_dht_round(state)}

      nil ->
        {:noreply, state}

      {_announce, tier_index, _tracker_index} ->
        {:noreply, dec_tier_batch(state, tier_index)}
    end
  end

  def handle_info({:DOWN, _, :process, pid, _}, %__MODULE__{torrent_pid: p} = state)
      when pid === p,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, _, :process, _, :normal}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {request, state} = pop_request(state, ref)

    case request do
      {:dht, _dht_hash} ->
        {:noreply, maybe_finish_dht_round(state)}

      {_announce, tier_index, _tracker_index} ->
        {:noreply, dec_tier_batch(state, tier_index)}

      _ ->
        {:noreply, state}
    end
  end

  # `retry_in: "never"` means the tracker is permanently unusable — a dead DNS
  # name (nxdomain, e.g. the defunct rarbg trackers) or a host that isn't a
  # tracker at all. Previously "never" was mapped to a 0s retry, so the dead
  # host was re-announced every cycle forever (pointless DNS lookups + log
  # noise). Now we disable it: drop it from the announce rotation for this
  # session, like libtorrent marks a tracker "not working".
  def handle_info({ref, %Tracker.Error{retry_in: retry_in} = error}, state)
      when retry_in in ["never", :never] do
    {meta, state} = pop_request(state, ref)

    case meta do
      {announce, tier_index, _tracker_index} ->
        Logger.info(
          "[tracker_announce] disabled announce=#{announce} reason=#{inspect(error.reason)}"
        )

        state =
          state
          |> Map.update!(:disabled, &MapSet.put(&1, announce))
          |> Map.update!(:peers, &Map.delete(&1, announce))
          |> dec_tier_batch(tier_index)

        {:noreply, state}

      {:scrape, announce} ->
        # BEP 48 not supported (:not_scrapeable or DNS "never"): remember so
        # the next scrape tick doesn't re-fire against this URL, but leave the
        # announce pipeline untouched — many trackers scrape=404 but announce=OK.
        Logger.debug(
          "[tracker_scrape] unsupported hash=#{Torrent.hex_encoded_hash(state.hash)} tracker=#{announce} reason=#{inspect(error.reason)}"
        )

        {:noreply, put_in(state.scrape_stats[announce], %{unsupported: true})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, %Tracker.Error{retry_in: retry_in} = error}, state)
      when not is_nil(retry_in) do
    timeout = retry_interval_seconds(retry_in, error.reason)
    {:noreply, parallel_tracker_error(state, ref, timeout)}
  end

  def handle_info({ref, %Tracker.Error{reason: reason}}, state) do
    timeout = retry_interval_seconds(nil, reason)
    {:noreply, parallel_tracker_error(state, ref, timeout)}
  end

  def handle_info({ref, _}, state) do
    {:noreply, parallel_tracker_error(state, ref, Tracker.default_failure_interval())}
  end

  @spec start_parallel_tier(%__MODULE__{}, non_neg_integer(), [String.t()]) :: %__MODULE__{}
  defp start_parallel_tier(%__MODULE__{hash: hash} = state, tier_index, tier) do
    now = System.monotonic_time(:millisecond)

    # Skip trackers disabled earlier this session (dead DNS / not-a-tracker)
    # and trackers whose own BEP 31 cooldown has not elapsed. Cooldown is
    # deliberately URL-local: ready siblings remain in this parallel batch.
    active =
      tier
      |> Enum.with_index()
      |> Enum.reject(fn {announce, _tracker_index} ->
        MapSet.member?(state.disabled, announce)
      end)
      |> Enum.filter(fn {announce, _tracker_index} ->
        tracker_retry_ready?(state, announce, now)
      end)

    # BEP 48 — also skip trackers with a fresh {0,0} scrape (dead swarm for
    # this info_hash). Kept separate from `disabled` so a later scrape or a
    # TTL expiry can re-include them without a restart.
    {alive, dead} =
      Enum.split_with(active, fn {announce, _tracker_index} ->
        tracker_alive?(state, announce, now)
      end)

    if dead != [] do
      Logger.debug(
        "[tracker_scrape] tier_skip hash=#{Torrent.hex_encoded_hash(hash)} tier=#{tier_index} dead=#{length(dead)} alive=#{length(alive)}"
      )
    end

    if alive == [] do
      # Under target, fan-out collection skips empty tiers; at target, hop serially.
      if Swarm.count(hash) >= @swarm_target_peers do
        next = next_tier_index(state.tiers, tier_index)
        schedule_parallel_announce(state, next, dead_tier_advance_sec(state, tier_index))
      end

      state
    else
      Logger.info(
        "[tracker_announce] parallel hash=#{Torrent.hex_encoded_hash(hash)} tier=#{tier_index} trackers=#{length(alive)}"
      )

      requests =
        alive
        |> Enum.reduce(state.requests, fn {announce, tracker_index}, acc ->
          tracker_opts = tracker_request_opts_for(state)

          %Task{ref: ref} =
            Task.Supervisor.async_nolink(Requests, Tracker, :request!, [
              announce,
              hash,
              :auto,
              tracker_opts
            ])

          Map.put(acc, ref, {announce, tier_index, tracker_index})
        end)

      tier_batches = Map.put(state.tier_batches, tier_index, length(alive))

      %{
        state
        | tier_index: tier_index,
          requests: requests,
          tier_batches: tier_batches
      }
    end
  end

  # At/over swarm target: one tier at a time (BEP tier semantics).
  @spec handle_at_target_tier_announce(%__MODULE__{}, non_neg_integer()) :: %__MODULE__{}
  defp handle_at_target_tier_announce(%__MODULE__{} = state, start_tier) do
    if tier_batches_active?(state) do
      state
    else
      {state, tier_index, resolve_status} = resolve_announcable_tier(state, start_tier)

      cond do
        resolve_status == :ring_exhausted ->
          state

        true ->
          case Enum.fetch(state.tiers, tier_index) do
            {:ok, tier} when tier != [] ->
              start_parallel_tier(state, tier_index, tier)

            {:ok, []} ->
              next = next_tier_index(state.tiers, tier_index)
              schedule_parallel_announce(state, next, dead_tier_advance_sec(state, tier_index))
              state

            :error ->
              send(self(), {:parallel_announce, 0})
              state
          end
      end
    end
  end

  # Under swarm target: fan out up to @under_target_tier_fanout announcable tiers
  # concurrently (global, not per-wave). Black-hole tier-0 UDP must not block
  # tier 1+ (opentrackr), but escalate refresh must not stack unbounded waves.
  @spec handle_under_target_tier_fanout(%__MODULE__{}, non_neg_integer()) ::
          {:noreply, %__MODULE__{}}
  defp handle_under_target_tier_fanout(%__MODULE__{} = state, start_tier) do
    slots = @under_target_tier_fanout - map_size(state.tier_batches)

    if slots <= 0 do
      {:noreply, state}
    else
      {state, tiers_to_start} = collect_fanout_tiers(state, start_tier, slots)

      case tiers_to_start do
        [] ->
          {_state, tier_index, status} = resolve_announcable_tier(state, start_tier)

          if status == :ring_exhausted do
            schedule_parallel_announce(
              state,
              tier_index,
              dead_tier_advance_sec(state, start_tier)
            )
          end

          {:noreply, state}

        started ->
          high_tier = started |> Enum.map(&elem(&1, 0)) |> Enum.max()

          state =
            Enum.reduce(started, %{state | fanout_high_tier: high_tier}, fn {tier_index, tier},
                                                                            acc ->
              start_parallel_tier(acc, tier_index, tier)
            end)

          {:noreply, state}
      end
    end
  end

  @spec collect_fanout_tiers(%__MODULE__{}, non_neg_integer(), pos_integer()) ::
          {%__MODULE__{}, [{non_neg_integer(), [String.t()]}]}
  defp collect_fanout_tiers(%__MODULE__{} = state, start_index, max_count) do
    now = System.monotonic_time(:millisecond)
    tier_count = length(state.tiers)
    selected = MapSet.new(Map.keys(state.tier_batches))

    do_collect_fanout_tiers(
      state,
      start_index,
      max_count,
      0,
      now,
      tier_count,
      selected,
      []
    )
  end

  @spec do_collect_fanout_tiers(
          %__MODULE__{},
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          MapSet.t(),
          [{non_neg_integer(), [String.t()]}]
        ) :: {%__MODULE__{}, [{non_neg_integer(), [String.t()]}]}
  defp do_collect_fanout_tiers(
         state,
         _tier_index,
         max_count,
         _hops,
         _now_ms,
         _tier_count,
         _selected,
         acc
       )
       when length(acc) >= max_count do
    {state, Enum.reverse(acc)}
  end

  defp do_collect_fanout_tiers(
         state,
         _tier_index,
         _max_count,
         hops,
         _now_ms,
         tier_count,
         _selected,
         acc
       )
       when hops >= tier_count do
    {state, Enum.reverse(acc)}
  end

  defp do_collect_fanout_tiers(
         %__MODULE__{tier_batches: batches, tiers: tiers} = state,
         tier_index,
         max_count,
         hops,
         now_ms,
         tier_count,
         selected,
         acc
       ) do
    if Map.has_key?(batches, tier_index) or MapSet.member?(selected, tier_index) do
      next = next_tier_index(tiers, tier_index)

      do_collect_fanout_tiers(state, next, max_count, hops + 1, now_ms, tier_count, selected, acc)
    else
      {state, resolved_index, status} = resolve_announcable_tier(state, tier_index)

      cond do
        status == :ring_exhausted and acc == [] ->
          {state, []}

        status == :ring_exhausted ->
          {state, Enum.reverse(acc)}

        Map.has_key?(batches, resolved_index) or MapSet.member?(selected, resolved_index) ->
          next = next_tier_index(tiers, resolved_index)

          do_collect_fanout_tiers(
            state,
            next,
            max_count,
            hops + 1,
            now_ms,
            tier_count,
            selected,
            acc
          )

        true ->
          case Enum.fetch(tiers, resolved_index) do
            {:ok, tier} ->
              alive = announcable_trackers_in_tier(state, tier, now_ms)

              if alive != [] do
                next = next_tier_index(tiers, resolved_index)
                selected = MapSet.put(selected, resolved_index)

                do_collect_fanout_tiers(
                  state,
                  next,
                  max_count,
                  hops + 1,
                  now_ms,
                  tier_count,
                  selected,
                  [{resolved_index, tier} | acc]
                )
              else
                next = next_tier_index(tiers, resolved_index)

                do_collect_fanout_tiers(
                  state,
                  next,
                  max_count,
                  hops + 1,
                  now_ms,
                  tier_count,
                  selected,
                  acc
                )
              end

            :error ->
              {state, Enum.reverse(acc)}
          end
      end
    end
  end

  @spec apply_tracker_response(
          %__MODULE__{},
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Tracker.Response.t()
        ) :: %__MODULE__{}
  defp apply_tracker_response(state, announce, tier_index, tracker_index, response) do
    # BEP min-interval applies only after a tracker answered — not when a batch
    # was merely dispatched (DNS nxdomain / timeout is not an announce).
    now = System.monotonic_time(:millisecond)

    state =
      state
      |> promote_tracker(tier_index, tracker_index)
      |> put_in([Access.key!(:peers), announce], response.peers)
      |> Map.put(:tracker_interval_sec, response.interval)
      |> Map.put(:tracker_min_interval_sec, response.min_interval)
      |> maybe_stamp_last_tracker_announce(response, now)

    log_tracker_success(state.hash, announce, response)
    Model.update_event(state.hash)

    if dht_allowed?(state) do
      announce_dht_hashes(state)
    end

    if Model.get(state.hash, :peer_status) != :seed do
      Acceptor.handshakes(response.peers, state.hash)
    end

    state
  end

  @spec dec_tier_batch(%__MODULE__{}, non_neg_integer()) :: %__MODULE__{}
  defp dec_tier_batch(%__MODULE__{tier_batches: batches} = state, tier_index) do
    case Map.get(batches, tier_index) do
      nil ->
        state

      1 ->
        batches = Map.delete(batches, tier_index)
        state = %{state | tier_batches: batches}

        state =
          if reschedule_same_tier_after_batch?(state) do
            interval = batch_announce_interval(state)
            schedule_parallel_announce(state, tier_index, interval)
            state
          else
            maybe_continue_fanout_wave(state, tier_index)
          end

        state

      remaining when remaining > 1 ->
        %{state | tier_batches: Map.put(batches, tier_index, remaining - 1)}
    end
  end

  @spec parallel_tracker_error(%__MODULE__{}, reference(), non_neg_integer()) :: %__MODULE__{}
  defp parallel_tracker_error(%__MODULE__{} = state, ref, timeout_seconds) do
    {meta, requests} = Map.pop(state.requests, ref)

    case meta do
      nil ->
        state

      {:scrape, _announce} ->
        # Scrape failures are non-fatal — the tracker's announce endpoint may
        # still work. Drop the request, leave parallel state and `disabled`
        # untouched. Retry on next @scrape_interval_ms tick.
        %{state | requests: requests}

      {announce, tier_index, _tracker_index} ->
        state
        |> Map.put(:requests, requests)
        |> Map.update!(:peers, &Map.delete(&1, announce))
        |> put_tracker_retry_after(announce, timeout_seconds)
        |> dec_tier_batch(tier_index)
    end
  end

  @spec put_tracker_retry_after(%__MODULE__{}, String.t(), non_neg_integer()) :: %__MODULE__{}
  defp put_tracker_retry_after(%__MODULE__{} = state, announce, timeout_seconds) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_seconds * 1_000
    put_in(state.retry_after_ms[announce], deadline_ms)
  end

  # A tier had no live trackers to contact (all disabled or BEP-48 dead scrape).
  # Under swarm target, hop to the next tier immediately — no announce was sent
  # so BEP min-interval does not apply. After a full tier ring with nothing to
  # announce, back off to the under-target cadence (~30 s) instead of
  # default_interval (30 min), which would park peer discovery for half an hour
  # behind CGNAT when tier-0 is dead (e.g. defunct rarbg).
  @spec dead_tier_advance_sec(%__MODULE__{}, non_neg_integer()) :: non_neg_integer()
  defp dead_tier_advance_sec(%__MODULE__{hash: hash} = state, tier_index) do
    next = next_tier_index(state.tiers, tier_index)

    cond do
      Swarm.count(hash) < @swarm_target_peers and next != 0 ->
        0

      Swarm.count(hash) < @swarm_target_peers ->
        @under_target_announce_sec

      true ->
        parallel_tier_reschedule_sec(state, Tracker.default_interval())
    end
  end

  # Reschedule after a parallel batch yields no peers (all trackers failed).
  # Under swarm target, keep cycling on the short cadence regardless of the
  # tracker's failure timeout; at target, honour tracker interval / fallback.
  @spec parallel_tier_reschedule_sec(%__MODULE__{}, non_neg_integer()) :: non_neg_integer()
  defp parallel_tier_reschedule_sec(%__MODULE__{hash: hash} = state, fallback_sec) do
    connected = Swarm.count(hash)
    min_sec = state.tracker_min_interval_sec || @announce_floor_sec

    cond do
      connected < @swarm_target_peers ->
        max(min_sec, @under_target_announce_sec)

      is_integer(state.tracker_interval_sec) and state.tracker_interval_sec > 0 ->
        max(min_sec, state.tracker_interval_sec)

      true ->
        max(min_sec, fallback_sec)
    end
  end

  # After a failed parallel batch with zero peers, hop to the next tier. Under
  # target, advance immediately (interval 0) so a dead tier-0 rarbg does not
  # block tier 1+ for 30 s while DHT peers time out on dial. Wrap to tier 0
  # uses the under-target cadence to avoid hammering the full ring.
  @spec parallel_tier_failure_advance_sec(%__MODULE__{}, non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp parallel_tier_failure_advance_sec(
         %__MODULE__{hash: hash} = state,
         tier_index,
         fallback_sec
       ) do
    next = next_tier_index(state.tiers, tier_index)

    cond do
      Swarm.count(hash) < @swarm_target_peers and next != 0 ->
        0

      Swarm.count(hash) < @swarm_target_peers ->
        @under_target_announce_sec

      true ->
        parallel_tier_reschedule_sec(state, fallback_sec)
    end
  end

  # CGNAT / peer-starved torrents: cap each parallel announce Task at ~15 s so a
  # single dead tracker cannot hold a `tier_batches` slot for the 5 min HTTP
  # default or the full BEP 15 UDP ladder. At/over swarm target, keep the
  # long BEP-friendly budgets in `Tracker.request!/4`.
  @spec tracker_request_opts_for(%__MODULE__{}) :: Tracker.request_opts()
  defp tracker_request_opts_for(%__MODULE__{hash: hash}) do
    if Swarm.count(hash) < @swarm_target_peers do
      Tracker.fast_fail_request_opts()
    else
      []
    end
  end

  @spec batch_announce_interval(%__MODULE__{}) :: non_neg_integer()
  defp batch_announce_interval(%__MODULE__{} = state), do: tracker_announce_interval_sec(state)

  @spec tracker_announce_interval_sec(%__MODULE__{}) :: pos_integer()
  defp tracker_announce_interval_sec(%__MODULE__{hash: hash} = state) do
    connected = Swarm.count(hash)
    min_sec = state.tracker_min_interval_sec || @announce_floor_sec

    cond do
      connected < @swarm_target_peers ->
        max(min_sec, @under_target_announce_sec)

      is_integer(state.tracker_interval_sec) and state.tracker_interval_sec > 0 ->
        max(min_sec, state.tracker_interval_sec)

      true ->
        max(min_sec, Tracker.default_interval())
    end
  end

  @spec dht_lookup_interval_sec(%__MODULE__{}) :: pos_integer()
  defp dht_lookup_interval_sec(%__MODULE__{hash: hash}) do
    connected = Swarm.count(hash)

    cond do
      connected < @dht_critical_threshold -> @dht_critical_sec
      connected < @swarm_target_peers -> @dht_floor_sec
      true -> @dht_interval_sec
    end
  end

  @spec maybe_refresh_under_target(%__MODULE__{}) :: %__MODULE__{}
  defp maybe_refresh_under_target(%__MODULE__{hash: hash} = state) do
    if Swarm.count(hash) < @swarm_target_peers do
      state
      |> maybe_schedule_tracker_announce()
      |> maybe_schedule_dht_lookup()
    else
      state
    end
  end

  @spec maybe_schedule_tracker_announce(%__MODULE__{}) :: %__MODULE__{}
  defp maybe_schedule_tracker_announce(%__MODULE__{tiers: [], tier_batches: batches} = state)
       when map_size(batches) == 0,
       do: state

  defp maybe_schedule_tracker_announce(
         %__MODULE__{tier_batches: batches, tier_index: tier_index} = state
       )
       when map_size(batches) == 0 do
    now = System.monotonic_time(:millisecond)

    if tracker_announce_allowed?(state, now) == :ok do
      send(self(), {:parallel_announce, tier_index})
    end

    state
  end

  defp maybe_schedule_tracker_announce(state), do: state

  @spec maybe_schedule_dht_lookup(%__MODULE__{}) :: %__MODULE__{}
  defp maybe_schedule_dht_lookup(%__MODULE__{} = state) do
    if dht_allowed?(state) and not dht_request_pending?(state) do
      now = System.monotonic_time(:millisecond)

      if dht_lookup_allowed?(state, now) == :ok do
        send(self(), :dht_lookup)
      end
    end

    state
  end

  @spec dht_request_pending?(%__MODULE__{}) :: boolean()
  defp dht_request_pending?(%__MODULE__{requests: requests}) do
    Enum.any?(requests, fn
      {_ref, {:dht, _hash}} -> true
      _ -> false
    end)
  end

  @spec schedule_parallel_announce(%__MODULE__{}, non_neg_integer(), non_neg_integer()) :: :ok
  # Interval 0 = hop now (dead-tier skip or failed batch under swarm target).
  # Must not be dropped — callers rely on immediate send to reach tier 1+ when
  # tier 0 is dead (e.g. defunct rarbg nxdomain).
  defp schedule_parallel_announce(_state, tier_index, 0) do
    send(self(), {:parallel_announce, tier_index})
    :ok
  end

  defp schedule_parallel_announce(state, tier_index, timeout_seconds) do
    jitter_ms =
      :erlang.phash2({state.hash, tier_index, System.monotonic_time()})
      |> rem(max(div(timeout_seconds * 100, 1), 1))

    send_after(self(), {:parallel_announce, tier_index}, timeout_seconds * 1_000 + jitter_ms)
  end

  @spec next_tier_index([list()], non_neg_integer()) :: non_neg_integer()
  defp next_tier_index(tiers, tier_index) do
    if tier_index + 1 < length(tiers), do: tier_index + 1, else: 0
  end

  # Under swarm target, skip consecutive tiers whose trackers are all session-
  # disabled or BEP-48 dead-scrape without dispatching announce Tasks — each
  # dead hop used to cost one mailbox turn and (worse) a 30 s wait when an
  # earlier tier returned peers=[] and stamped last_tracker_announce_ms.
  @spec resolve_announcable_tier(%__MODULE__{}, non_neg_integer()) ::
          {%__MODULE__{}, non_neg_integer(), :live | :ring_exhausted}
  defp resolve_announcable_tier(%__MODULE__{hash: hash, tiers: tiers} = state, start_index) do
    tier_count = length(tiers)
    now = System.monotonic_time(:millisecond)

    cond do
      tier_count == 0 ->
        {state, start_index, :ring_exhausted}

      Swarm.count(hash) >= @swarm_target_peers ->
        {Map.put(state, :tier_index, start_index), start_index, :live}

      tier_announcable?(state, start_index, now) ->
        {Map.put(state, :tier_index, start_index), start_index, :live}

      true ->
        do_skip_dead_tiers(state, start_index, start_index, 0, now, tier_count)
    end
  end

  @spec do_skip_dead_tiers(
          %__MODULE__{},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {%__MODULE__{}, non_neg_integer(), :live | :ring_exhausted}
  defp do_skip_dead_tiers(state, start_index, tier_index, hops, now_ms, tier_count) do
    next = next_tier_index(state.tiers, tier_index)

    cond do
      tier_announcable?(state, next, now_ms) ->
        {Map.put(state, :tier_index, next), next, :live}

      hops + 1 >= tier_count ->
        schedule_parallel_announce(state, next, dead_tier_advance_sec(state, tier_index))
        {state, tier_index, :ring_exhausted}

      true ->
        do_skip_dead_tiers(state, start_index, next, hops + 1, now_ms, tier_count)
    end
  end

  @spec tier_announcable?(%__MODULE__{}, non_neg_integer(), non_neg_integer()) :: boolean()
  defp tier_announcable?(%__MODULE__{tiers: tiers} = state, tier_index, now_ms) do
    case Enum.fetch(tiers, tier_index) do
      {:ok, tier} -> announcable_trackers_in_tier(state, tier, now_ms) != []
      :error -> false
    end
  end

  @spec announcable_trackers_in_tier(%__MODULE__{}, [String.t()], non_neg_integer()) ::
          [String.t()]
  defp announcable_trackers_in_tier(%__MODULE__{} = state, tier, now_ms) do
    tier
    |> Enum.reject(&MapSet.member?(state.disabled, &1))
    |> Enum.filter(&tracker_retry_ready?(state, &1, now_ms))
    |> Enum.filter(&tracker_alive?(state, &1, now_ms))
  end

  @spec tracker_retry_ready?(%__MODULE__{}, String.t(), integer()) :: boolean()
  defp tracker_retry_ready?(%__MODULE__{retry_after_ms: retry_after_ms}, announce, now_ms) do
    case Map.get(retry_after_ms, announce) do
      nil -> true
      deadline_ms -> now_ms >= deadline_ms
    end
  end

  # After the last in-flight tracker Task in a fan-out wave completes with no peers,
  # schedule the next wave from the tier after fanout_high_tier (not serially from
  # the tier that just finished — other tiers in the wave may still be running).
  @spec maybe_continue_fanout_wave(%__MODULE__{}, non_neg_integer()) :: %__MODULE__{}
  defp maybe_continue_fanout_wave(%__MODULE__{} = state, completed_tier) do
    if map_size(state.tier_batches) == 0 and starved_with_no_tracker_peers?(state) do
      anchor = state.fanout_high_tier || completed_tier
      next = next_tier_index(state.tiers, anchor)
      interval = parallel_tier_failure_advance_sec(state, anchor, @under_target_announce_sec)
      schedule_parallel_announce(state, next, interval)
    end

    state
  end

  @spec reschedule_same_tier_after_batch?(%__MODULE__{}) :: boolean()
  defp reschedule_same_tier_after_batch?(%__MODULE__{hash: hash} = state) do
    not (Swarm.count(hash) < @swarm_target_peers and tracker_peers_empty?(state))
  end

  @spec starved_with_no_tracker_peers?(%__MODULE__{}) :: boolean()
  defp starved_with_no_tracker_peers?(%__MODULE__{hash: hash} = state) do
    Swarm.count(hash) < @swarm_target_peers and tracker_peers_empty?(state)
  end

  @spec maybe_stamp_last_tracker_announce(%__MODULE__{}, Tracker.Response.t(), non_neg_integer()) ::
          %__MODULE__{}
  defp maybe_stamp_last_tracker_announce(%__MODULE__{hash: hash} = state, response, now_ms) do
    if response.peers != [] or Swarm.count(hash) >= @swarm_target_peers do
      Map.put(state, :last_tracker_announce_ms, now_ms)
    else
      state
    end
  end

  @spec schedule_pex(pid(), pos_integer()) :: reference()
  defp schedule_pex(pid, ms), do: send_after(pid, :pex_broadcast, ms)

  @spec maybe_broadcast_pex(%__MODULE__{}) :: %__MODULE__{}
  defp maybe_broadcast_pex(%__MODULE__{private?: true} = state), do: state

  defp maybe_broadcast_pex(%__MODULE__{hash: hash} = state) do
    current =
      try do
        live = Peer.UtPex.snapshot_map(hash)

        {current, _drained} =
          Peer.UtPex.Outbound.prepare_current(hash, live,
            supplement_recent?: true,
            drain_recent?: true
          )

        current
      catch
        :exit, _ -> state.pex_snapshot
      end

    apply_pex_snapshot_delta(state, current)
  end

  @spec apply_pex_snapshot_delta(%__MODULE__{}, map()) :: %__MODULE__{}
  defp apply_pex_snapshot_delta(%__MODULE__{hash: hash} = state, current) do
    # Always fan the snapshot out on the minute tick. A controller may still
    # have capped spillover even when the torrent-global live set is unchanged;
    # its per-connection sent map makes an unchanged tick a cheap no-op.
    _ = Peer.UtPex.broadcast_snapshot(hash, current)
    %{state | pex_snapshot: current}
  end

  # BEP 12: on success, move the working tracker to the front of its tier.
  @spec promote_tracker(%__MODULE__{}, non_neg_integer(), non_neg_integer()) :: %__MODULE__{}
  defp promote_tracker(%__MODULE__{tiers: tiers} = state, tier_index, tracker_index) do
    case Enum.fetch(tiers, tier_index) do
      {:ok, tier} ->
        {tracker, rest} = List.pop_at(tier, tracker_index)
        promoted_tier = [tracker | List.delete(rest, tracker)]
        put_in(state, [Access.key!(:tiers), Access.at(tier_index)], promoted_tier)

      :error ->
        state
    end
  end

  @spec parse_retry_in_seconds(binary()) :: non_neg_integer() | nil
  defp parse_retry_in_seconds(str) do
    case String.split(str, ~r"[^0-9]", parts: 2) do
      [<<>>, _] -> nil
      [number, _] -> String.to_integer(number)
      [number] -> String.to_integer(number)
      _ -> nil
    end
  end

  @spec retry_interval_seconds(term(), term()) :: non_neg_integer()
  defp retry_interval_seconds(retry_in, _reason) when is_integer(retry_in) and retry_in >= 0,
    do: retry_in

  defp retry_interval_seconds(retry_in, _reason) when retry_in in ["never", :never], do: 0

  defp retry_interval_seconds(retry_in, _reason) when is_binary(retry_in) do
    case parse_retry_in_seconds(retry_in) do
      nil -> Tracker.default_failure_interval()
      n -> n
    end
  end

  defp retry_interval_seconds(_, reason) do
    # Dead public trackers (NXDOMAIN / black-hole UDP / connect timeouts) are the
    # common case in real announce-lists — BEP 12 already fails over tiers. Warn
    # only on unexpected reasons so server.log stays readable under CGNAT churn.
    if expected_tracker_failure_reason?(reason) do
      Logger.debug("request failure reason: #{inspect(reason)}")
    else
      Logger.warning("request failure reason: #{inspect(reason)}")
    end

    Tracker.default_failure_interval()
  end

  @doc false
  @spec expected_tracker_failure_reason?(term()) :: boolean()
  def expected_tracker_failure_reason?(reason)
      when reason in [
             :timeout,
             :nxdomain,
             :connect_timeout,
             :econnrefused,
             :closed,
             :enetunreach,
             :ehostunreach,
             :eaddrnotavail
           ],
      do: true

  def expected_tracker_failure_reason?({:nxdomain, _}), do: true
  def expected_tracker_failure_reason?(_), do: false

  @spec extract_tiers(map()) :: [list(String.t())]
  defp extract_tiers(%{"announce-list" => tiers}) when is_list(tiers) do
    tiers
    |> Enum.map(&normalize_tier/1)
    |> Enum.reject(&(&1 == []))
  end

  defp extract_tiers(%{"announce" => x}), do: [[x]]

  defp extract_tiers(%{"nodes" => nodes}) when is_list(nodes) do
    bootstrap_torrent_nodes(%{"nodes" => nodes})
    []
  end

  defp extract_tiers(_), do: []

  @spec normalize_tier(term()) :: [String.t()]
  defp normalize_tier(tier) when is_list(tier), do: Enum.map(tier, &to_string/1)
  defp normalize_tier(tier) when is_binary(tier), do: [tier]
  defp normalize_tier(_), do: []

  defp merged_peers(%__MODULE__{
         hash: hash,
         peers: peers_map,
         dht_peers: dht_peers,
         dht_round_peers: dht_round_peers,
         seed_peers: seed_peers
       }) do
    tracker_peers =
      peers_map
      |> Map.values()
      |> List.flatten()

    listen_port = Acceptor.port()

    merged =
      (tracker_peers ++ dht_peers ++ dht_round_peers ++ seed_peers)
      |> Enum.uniq_by(&{&1.ip, &1.port})
      |> Enum.reject(&Acceptor.Connection.Handshakes.local_endpoint?(&1.ip, &1.port, listen_port))

    if merged != [] do
      Logger.debug(
        "[peer_discovery] peers_merged hash=#{Torrent.hex_encoded_hash(hash)} count=#{length(merged)}"
      )
    end

    merged
  end

  @spec merge_dht_round_peers(%__MODULE__{}, [Peer.t()]) :: %__MODULE__{}
  defp merge_dht_round_peers(%__MODULE__{dht_round_peers: existing} = state, peers) do
    merged = Enum.uniq_by(existing ++ peers, &{&1.ip, &1.port})
    %{state | dht_round_peers: merged}
  end

  @spec maybe_finish_dht_round(%__MODULE__{}) :: %__MODULE__{}
  defp maybe_finish_dht_round(%__MODULE__{} = state) do
    if dht_request_pending?(state), do: state, else: finish_dht_round(state)
  end

  @spec finish_dht_round(%__MODULE__{}) :: %__MODULE__{}
  defp finish_dht_round(%__MODULE__{dht_round_peers: []} = state) do
    if dht_allowed?(state), do: send_after(self(), :dht_lookup, dht_retry_ms(state))
    state
  end

  defp finish_dht_round(%__MODULE__{hash: hash, dht_round_peers: peers} = state) do
    Logger.info(
      "dht get_peers ok hash=#{Torrent.hex_encoded_hash(hash)} peers=#{length(peers)} connected=#{Swarm.count(hash)}"
    )

    state = %{state | dht_peers: peers, dht_round_peers: []}

    if dht_allowed?(state) do
      announce_dht_hashes(state)
      send_after(self(), :dht_lookup, dht_retry_ms(state))
    end

    state
  end

  @spec maybe_handshake_dht_peers(%__MODULE__{}, [Peer.t()]) :: :ok
  defp maybe_handshake_dht_peers(%__MODULE__{hash: hash} = state, peers) do
    if peers != [] and dht_allowed?(state) and Model.get(hash, :peer_status) != :seed do
      Acceptor.handshakes(peers, hash)
    end

    :ok
  end

  @spec dht_hashes(%__MODULE__{}) :: [Torrent.hash()]
  defp dht_hashes(%__MODULE__{dht_hashes: [], hash: hash}), do: [hash]
  defp dht_hashes(%__MODULE__{dht_hashes: hashes}), do: hashes

  @spec announce_dht_hashes(%__MODULE__{}) :: :ok
  defp announce_dht_hashes(%__MODULE__{dht_module: dht_module} = state) do
    Enum.each(dht_hashes(state), fn hash ->
      _ignored = dht_module.announce(hash, Acceptor.port())
    end)

    :ok
  end

  @spec bootstrap_torrent_nodes(map()) :: :ok
  defp bootstrap_torrent_nodes(%{"nodes" => nodes}) when is_list(nodes) do
    Enum.each(nodes, fn
      [host, port] when is_binary(host) and is_integer(port) ->
        seed_dht_host(host, port)

      _ ->
        :ok
    end)
  end

  defp bootstrap_torrent_nodes(_), do: :ok

  @spec seed_dht_host(String.t(), :inet.port_number()) :: :ok
  defp seed_dht_host(host, port) do
    case :inet.gethostbyname(String.to_charlist(host)) do
      {:ok, {:hostent, _name, _aliases, _type, _len, [ip | _]}} ->
        _ignored = DHT.seed_node(ip, port)

      _ ->
        :ok
    end
  end

  @spec dht_retry_ms(%__MODULE__{}) :: pos_integer()
  defp dht_retry_ms(%__MODULE__{hash: hash} = state) do
    # Prev: hard-coded 5 min even when the swarm sat below target. One completed
    # (or errored) lookup would then leave the next retry timer at 5 min while
    # the torrent starved for peers. Align with `dht_lookup_interval_sec` so
    # critical / under-target torrents retry on the same cadence as scheduled
    # lookups; floor at 60 s so a persistently broken DHT infra isn't hammered.
    base = max(dht_lookup_interval_sec(state), 60) * 1_000

    jitter =
      :erlang.phash2({hash, System.monotonic_time()})
      |> rem(max(div(base, 10), 1))

    base + jitter
  end

  @spec log_tracker_success(Torrent.hash(), String.t(), Tracker.Response.t()) :: :ok
  defp log_tracker_success(hash, announce, %Tracker.Response{} = response) do
    Logger.info(
      "tracker announce ok hash=#{Torrent.hex_encoded_hash(hash)} tracker=#{announce} peers=#{length(response.peers)} seeders=#{response.complete} leechers=#{response.incomplete}"
    )
  end

  @spec dht_allowed?(%__MODULE__{}) :: boolean()
  defp dht_allowed?(%__MODULE__{private?: true}), do: false
  defp dht_allowed?(_), do: DHT.enabled?()

  @spec pex_allowed?(%__MODULE__{}) :: boolean()
  defp pex_allowed?(%__MODULE__{private?: true}), do: false
  defp pex_allowed?(_), do: true

  # BEP 48 — a tracker is "alive" for this info_hash unless a recent scrape
  # explicitly told us there are 0 seeders AND 0 leechers. Anything else
  # (positive counts, no scrape yet, stale scrape, scrape failure, tracker
  # doesn't support scrape) → treat as alive and let the announce proceed.
  @spec tracker_alive?(%__MODULE__{}, String.t(), non_neg_integer()) :: boolean()
  defp tracker_alive?(%__MODULE__{scrape_stats: stats}, announce, now_ms) do
    case Map.get(stats, announce) do
      %{seeders: 0, leechers: 0, ts_ms: ts} when now_ms - ts < @scrape_ttl_ms -> false
      _ -> true
    end
  end

  # Periodic scrape tick — fan out one BEP 48 scrape per unique announce URL
  # under this torrent's tiers. Deliberately skips URLs that are `disabled`
  # (dead DNS / not-a-tracker) or already flagged `%{unsupported: true}` (scrape
  # returned `retry_in: "never"` previously). Scrape refs are stored under
  # `{:scrape, announce}` in `requests` so the Tracker.Error handlers can tell
  # scrape failures from announce failures.
  @spec start_scrapes(%__MODULE__{}) :: %__MODULE__{}
  defp start_scrapes(%__MODULE__{tiers: [], scrape_stats: _} = state), do: state

  defp start_scrapes(%__MODULE__{hash: hash, tiers: tiers, disabled: disabled} = state) do
    urls =
      tiers
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(disabled, &1))
      |> Enum.reject(&scrape_unsupported?(state, &1))

    if urls == [] do
      state
    else
      Logger.debug(
        "[tracker_scrape] tick hash=#{Torrent.hex_encoded_hash(hash)} urls=#{length(urls)}"
      )

      requests =
        Enum.reduce(urls, state.requests, fn announce, acc ->
          %Task{ref: ref} =
            Task.Supervisor.async_nolink(Requests, Tracker, :scrape, [announce, hash])

          Map.put(acc, ref, {:scrape, announce})
        end)

      %{state | requests: requests, last_scrape_ms: System.monotonic_time(:millisecond)}
    end
  end

  @spec scrape_unsupported?(%__MODULE__{}, String.t()) :: boolean()
  defp scrape_unsupported?(%__MODULE__{scrape_stats: stats}, announce) do
    case Map.get(stats, announce) do
      %{unsupported: true} -> true
      _ -> false
    end
  end
end

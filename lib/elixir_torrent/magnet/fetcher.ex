defmodule Magnet.Fetcher do
  @moduledoc false

  require Logger

  alias DHT.Config, as: DHTConfig

  @max_peers 60
  @max_connections 16

  @doc false
  @spec max_connections() :: pos_integer()
  def max_connections, do: @max_connections
  @connection_pool_size 6
  @metadata_peer_timeout_ms 40_000
  @tracker_task_timeout_ms 50_000
  @tracker_max_concurrency 8
  @tracker_request_opts [max_udp_attempts: 1, http_timeout_ms: 8_000]

  @round_backoff_base_ms 30_000
  @round_backoff_step_ms 5_000
  @round_backoff_cap_ms 120_000
  # Reachable leechers without metadata are a sampling miss, not a dead swarm — retry
  # sooner than the normal round ramp (discovery cadence unchanged).
  @round_backoff_dead_leecher_ms 15_000
  # BEP 9 metadata fetch is retry-forever by design; cap wall-clock lifetime so a
  # dead magnet (no metadata peers) cannot hold ConnectionLimit slots + pending UI
  # rows indefinitely (e.g. 7D2978A2 stuck since Jul 16).
  @max_fetch_lifetime_ms 24 * 60 * 60 * 1_000

  defp fetcher_cfg(key, default) do
    Application.get_env(:elixir_torrent, :magnet_fetcher, [])
    |> Keyword.get(key, default)
  end

  @doc false
  @spec max_fetch_lifetime_ms() :: pos_integer()
  def max_fetch_lifetime_ms, do: fetcher_cfg(:max_fetch_lifetime_ms, @max_fetch_lifetime_ms)

  defp metadata_peer_timeout_ms,
    do: fetcher_cfg(:metadata_peer_timeout_ms, @metadata_peer_timeout_ms)

  defp round_backoff_base_ms, do: fetcher_cfg(:round_backoff_base_ms, @round_backoff_base_ms)
  defp round_backoff_step_ms, do: fetcher_cfg(:round_backoff_step_ms, @round_backoff_step_ms)
  defp round_backoff_cap_ms, do: fetcher_cfg(:round_backoff_cap_ms, @round_backoff_cap_ms)

  defp round_backoff_dead_leecher_ms,
    do: fetcher_cfg(:round_backoff_dead_leecher_ms, @round_backoff_dead_leecher_ms)

  @type ref :: reference()
  @type progress :: Magnet.Fetcher.Session.progress()

  @doc """
  Starts a persistent background metadata fetch for `magnet`.

  Sends `{:magnet_fetch_progress, ref, progress}` during retries and
  `{:magnet_fetch, ref, result}` when metadata is obtained or a fatal error occurs.
  """
  @spec run(Magnet.t(), pid()) :: {:ok, ref()} | {:error, term()}
  def run(%Magnet{} = magnet, caller \\ self()) do
    if missing_peers_source?(magnet) do
      {:error, :missing_trackers}
    else
      ref = make_ref()

      registry_key = {:magnet_fetch, magnet.hash}

      case Registry.lookup(Registry, registry_key) do
        [{pid, _}] when is_pid(pid) ->
          {:error, {:already_fetching, pid}}

        [] ->
          child_spec = %{
            id: registry_key,
            start: {Magnet.Fetcher.Session, :start_link, [{magnet, caller, ref}]},
            restart: :temporary
          }

          case DynamicSupervisor.start_child(Magnet.Fetcher.Supervisor, child_spec) do
            {:ok, _pid} ->
              {:ok, ref}

            {:error, {:already_started, pid}} ->
              {:error, {:already_fetching, pid}}

            {:error, _} = error ->
              error
          end
      end
    end
  end

  @doc """
  Waits for the result of a fetch started with `run/2`.

  Defaults to `:infinity` so persistent fetches are not cut off prematurely.
  """
  @spec await(ref(), timeout()) :: {:ok, Path.t()} | {:error, term()}
  def await(ref, timeout \\ :infinity) do
    receive do
      {:magnet_fetch, ^ref, {:ok, path}} when is_binary(path) ->
        {:ok, path}

      {:magnet_fetch, ^ref, {:error, _} = error} ->
        error
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Stops a persistent metadata fetch for `hash`, if one is running.
  """
  @spec cancel(Torrent.hash()) :: :ok
  def cancel(hash) when is_binary(hash) do
    key = {:magnet_fetch, hash}

    case Registry.lookup(Registry, key) do
      [{pid, _}] when is_pid(pid) ->
        send(pid, :cancel)
        :ok

      _ ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Stops any in-flight metadata fetch and bootstrap swarm for `hash` before starting
  a normal torrent download for the same info-hash.
  """
  @spec prepare_for_download(Torrent.hash()) :: :ok
  def prepare_for_download(hash) when is_binary(hash) do
    :ok = stop_fetch_session(hash)
    :ok = Magnet.Bootstrap.stop(hash)
    :ok
  end

  @cancel_await_ms 500

  @spec stop_fetch_session(Torrent.hash()) :: :ok
  defp stop_fetch_session(hash) do
    case Registry.lookup(Registry, {:magnet_fetch, hash}) do
      [{pid, _}] when is_pid(pid) ->
        send(pid, :cancel)
        :ok = await_process_down(pid, @cancel_await_ms)

        if Process.alive?(pid) do
          Process.exit(pid, :shutdown)
          :ok = await_process_down(pid, @cancel_await_ms)
        end

        :ok

      _ ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec await_process_down(pid(), non_neg_integer()) :: :ok
  defp await_process_down(pid, timeout_ms) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout_ms -> :ok
    end
  end

  @doc false
  @spec round_backoff_ms(pos_integer(), term()) :: pos_integer()
  def round_backoff_ms(round, reason \\ nil)

  def round_backoff_ms(round, reason) when is_integer(round) and round > 0 do
    base =
      min(round_backoff_cap_ms(), round_backoff_base_ms() + (round - 1) * round_backoff_step_ms())

    if dead_leecher_round_failure?(reason) do
      min(base, round_backoff_dead_leecher_ms())
    else
      base
    end
  end

  @doc false
  @spec dead_leecher_round_failure?(term()) :: boolean()
  def dead_leecher_round_failure?({:metadata_unavailable, failures}) when is_list(failures) do
    failures != [] and Enum.all?(failures, &leecher_sampling_failure?/1)
  end

  def dead_leecher_round_failure?(:metadata_unavailable), do: true
  def dead_leecher_round_failure?(:no_swarm_metadata_peers), do: false
  def dead_leecher_round_failure?(:no_peers), do: false
  def dead_leecher_round_failure?(:round_worker_crashed), do: false
  def dead_leecher_round_failure?(_), do: false

  @leecher_sampling_failures [
    :peer_died,
    :metadata_unavailable,
    :no_ut_metadata,
    :metadata_size_pending,
    :no_metadata_session
  ]

  defp leecher_sampling_failure?(reason) when reason in @leecher_sampling_failures, do: true
  defp leecher_sampling_failure?(_), do: false

  @doc false
  @spec discover_and_merge_peers(Magnet.t(), keyword(), %{peer_key() => Peer.t()}) ::
          {%{peer_key() => Peer.t()}, non_neg_integer(), [String.t()]}
  def discover_and_merge_peers(%Magnet{} = magnet, stats, known_peers) when is_map(known_peers) do
    {discovered, announced_trackers} = discover_peers(magnet, stats)
    before = map_size(known_peers)

    merged =
      Enum.reduce(discovered, known_peers, fn %Peer{} = peer, acc ->
        Map.put(acc, peer_key(peer), peer)
      end)

    peers_new = max(map_size(merged) - before, 0)
    {merged, peers_new, announced_trackers}
  end

  @doc false
  @spec announce_dht_for_metadata(Torrent.hash()) :: :ok
  def announce_dht_for_metadata(hash) when is_binary(hash) do
    # BEP 5 — announce while still fetching metadata so we appear in other nodes'
    # get_peers peer lists and attract reciprocal inbound under CGNAT (weak outbound v4).
    if DHT.enabled?() do
      DHT.announce(hash, Acceptor.port())
    else
      :ok
    end
  end

  @doc false
  @spec select_peers_for_round(%{peer_key() => Peer.t()}, %{peer_key() => non_neg_integer()}) ::
          [Peer.t()]
  def select_peers_for_round(known_peers, peer_attempts) when is_map(known_peers) do
    known_peers
    |> Map.values()
    |> Enum.sort_by(fn %Peer{} = peer ->
      # Prefer IPv6 before truncating to @max_peers — tracker floods of v4 must not
      # crowd out the scarce v6 candidates that actually dial on this host.
      {Map.get(peer_attempts, peer_key(peer), 0), not ipv6_peer?(peer)}
    end)
    |> Enum.take(@max_peers)
    |> shuffle()
  end

  @doc false
  @spec mark_peers_attempted(%{peer_key() => non_neg_integer()}, [Peer.t()]) ::
          %{peer_key() => non_neg_integer()}
  def mark_peers_attempted(peer_attempts, peers) when is_map(peer_attempts) and is_list(peers) do
    Enum.reduce(peers, peer_attempts, fn %Peer{} = peer, acc ->
      key = peer_key(peer)
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  @doc false
  @spec fetch_metadata_round(Magnet.t(), [Peer.t()], [String.t()]) ::
          {:ok, Path.t(), [String.t()], boolean()} | {:error, term()}
  def fetch_metadata_round(%Magnet{} = _magnet, [], _announced_trackers),
    do: {:error, :no_peers}

  def fetch_metadata_round(%Magnet{} = magnet, peers, announced_trackers) do
    hash_hex = Torrent.hex_encoded_hash(magnet.hash)

    Logger.info("[magnet_fetch] metadata_start hash=#{hash_hex} peers=#{length(peers)}")

    _ = Magnet.Bootstrap.ensure(magnet)
    _ = Magnet.Bootstrap.offer_peers(magnet.hash, peers)

    case Magnet.ConnectedMetadata.fetch(magnet, announced_trackers) do
      {:ok, _, _, _} = ok ->
        Magnet.Bootstrap.stop(magnet.hash)
        ok

      {:error, :info_hash_mismatch} = error ->
        Magnet.Bootstrap.stop(magnet.hash)
        error

      {:error, swarm_reason} ->
        Logger.info(
          "[magnet_fetch] swarm_failed hash=#{hash_hex} reason=#{inspect(swarm_reason)} trying_direct"
        )

        case fetch_metadata(magnet, peers, announced_trackers) do
          {:ok, _, _, _} = ok ->
            Magnet.Bootstrap.stop(magnet.hash)
            ok

          {:error, :info_hash_mismatch} = error ->
            Magnet.Bootstrap.stop(magnet.hash)
            error

          {:error, :metadata_unavailable} ->
            Magnet.Bootstrap.stop(magnet.hash)
            merge_metadata_unavailable_errors(swarm_reason, :metadata_unavailable)
        end
    end
  end

  @doc false
  @spec announce_stopped(Torrent.hash(), [String.t()]) :: :ok
  def announce_stopped(hash, trackers), do: announce_stopped_impl(hash, trackers)

  @doc """
  Invoked when metadata has been verified and written to `path`.

  Calls the optional `:metadata_ok_handler` application env callback `{magnet, path}`.
  """
  @spec on_metadata_ok(Magnet.t(), Path.t()) :: :ok
  def on_metadata_ok(%Magnet{} = magnet, path) when is_binary(path) do
    Magnet.Bootstrap.stop(magnet.hash)
    # BEP 9 § Magnet URI format — hand off x.pe endpoints so the fresh Announce
    # process seeds them into ConnectionManager instead of losing them with the
    # fetcher shutdown. Announce.take consumes the entry on first start.
    _ = PeerDiscovery.SeedPeers.put(magnet.hash, magnet.x_pe_peers)

    case Application.get_env(:elixir_torrent, :metadata_ok_handler) do
      handler when is_function(handler, 2) ->
        handler.(magnet, path)

      _ ->
        :ok
    end
  end

  @doc false
  @spec fetch_session_active?(Torrent.hash()) :: boolean()
  def fetch_session_active?(hash) when is_binary(hash) do
    case Registry.lookup(Registry, {:magnet_fetch, hash}) do
      [{pid, _}] when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  Merges tracker URLs (and display name) from `magnet` into a running fetch session.

  When a fuller magnet link arrives while metadata fetch is already in progress, this
  upgrades the session instead of ignoring the new trackers.
  """
  @spec upgrade_magnet(Torrent.hash(), Magnet.t()) :: :ok
  def upgrade_magnet(hash, %Magnet{} = magnet) when is_binary(hash) do
    case Registry.lookup(Registry, {:magnet_fetch, hash}) do
      [{pid, _}] when is_pid(pid) ->
        send(pid, {:upgrade_magnet, magnet})
        :ok

      _ ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec missing_peers_source?(Magnet.t()) :: boolean()
  defp missing_peers_source?(%Magnet{trackers: [], x_pe_peers: []}),
    do: not DHT.enabled?()

  defp missing_peers_source?(_), do: false

  @type peer_key :: {:inet.ip_address(), :inet.port_number()}

  @spec peer_key(Peer.t()) :: peer_key()
  defp peer_key(%Peer{ip: ip, port: port}), do: {ip, port}

  @spec ipv6_peer?(Peer.t()) :: boolean()
  defp ipv6_peer?(%Peer{ip: ip}), do: tuple_size(ip) == 8

  @tracker_await_cap_ms 120_000
  @magnet_tracker_task_timeout_ms 12_000

  @spec discover_peers(Magnet.t(), keyword()) :: {[Peer.t()], [String.t()]}
  defp discover_peers(%Magnet{} = magnet, stats) do
    background_dht = take_background_dht_peers(magnet.hash)

    tracker_task = Task.async(fn -> collect_tracker_peers(magnet, stats) end)

    dht_task =
      if DHT.enabled?() do
        Task.async(fn -> dht_peers_with_retry(magnet.hash, include_deep: false) end)
      end

    tracker_timeout = min(tracker_await_timeout_ms(magnet), @tracker_await_cap_ms)

    {tracker_peers, announced_trackers} =
      try do
        Task.await(tracker_task, tracker_timeout)
      catch
        :exit, _ ->
          Logger.warning(
            "[magnet_fetch] tracker_discovery_timeout hash=#{Torrent.hex_encoded_hash(magnet.hash)} timeout_ms=#{tracker_timeout}"
          )

          {[], Enum.uniq(magnet.trackers)}
      end

    quick_dht_peers = await_dht_peers(dht_task)

    dht_peers_list =
      cond do
        quick_dht_peers != [] ->
          quick_dht_peers

        not DHT.enabled?() ->
          []

        tracker_peers == [] ->
          dht_peers_deep_retry(magnet.hash)

        true ->
          maybe_spawn_dht_deep_background(magnet.hash)
          []
      end

    dht_peers_list = background_dht ++ dht_peers_list
    x_pe_peers = magnet.x_pe_peers

    peers =
      (x_pe_peers ++ tracker_peers ++ dht_peers_list)
      |> Enum.uniq_by(&peer_key/1)
      |> Enum.take(@max_peers)

    Logger.info(
      "[magnet_fetch] peer_discovery hash=#{Torrent.hex_encoded_hash(magnet.hash)} trackers=#{length(magnet.trackers)} x_pe=#{length(x_pe_peers)} tracker_peers=#{length(tracker_peers)} dht_peers=#{length(dht_peers_list)} unique=#{length(peers)}"
    )

    {peers, announced_trackers}
  end

  @dht_retry_delays_ms [0, 2_000, 5_000, 8_000]
  # One last dig after quick retries — bounded so a round gains at most ~15s wall clock.
  @dht_deep_retry_delay_ms 13_000
  @dht_bg_table :magnet_fetcher_dht_background

  @doc false
  @spec dht_deep_retry_delay_ms() :: pos_integer()
  def dht_deep_retry_delay_ms, do: @dht_deep_retry_delay_ms

  @spec dht_peers_with_retry(Torrent.hash(), keyword()) :: [Peer.t()]
  defp dht_peers_with_retry(hash, opts) do
    include_deep = Keyword.get(opts, :include_deep, true)

    peers = dht_peers_quick_retries(hash)

    cond do
      peers != [] -> peers
      include_deep -> dht_peers_deep_retry(hash)
      true -> []
    end
  end

  @spec dht_peers_quick_retries(Torrent.hash()) :: [Peer.t()]
  defp dht_peers_quick_retries(hash) do
    hash_hex = Torrent.hex_encoded_hash(hash)

    Enum.reduce_while(@dht_retry_delays_ms, [], fn delay, _acc ->
      case dht_get_peers_after_delay(hash, delay) do
        [] ->
          {:cont, []}

        peers ->
          log_dht_peers_found(hash_hex, peers, delay)
          {:halt, peers}
      end
    end)
  end

  @spec dht_peers_deep_retry(Torrent.hash()) :: [Peer.t()]
  defp dht_peers_deep_retry(hash) do
    hash_hex = Torrent.hex_encoded_hash(hash)

    # BEP 5 — announce_peer plants us on nearby nodes, but get_peers right after
    # often returns empty: peers need a propagation window before they show up.
    peers = dht_get_peers_after_delay(hash, @dht_deep_retry_delay_ms)

    if peers != [] do
      log_dht_peers_found(hash_hex, peers, @dht_deep_retry_delay_ms, deep: true)
    end

    peers
  end

  @spec dht_get_peers_after_delay(Torrent.hash(), non_neg_integer()) :: [Peer.t()]
  defp dht_get_peers_after_delay(hash, delay) do
    if delay > 0, do: Process.sleep(delay)

    # Plant ourselves in the DHT before each get_peers attempt (idempotent via
    # DHT announce_pending?); cold magnets previously only announced after metadata.
    :ok = announce_dht_for_metadata(hash)
    dht_peers(hash)
  end

  @spec log_dht_peers_found(String.t(), [Peer.t()], non_neg_integer(), keyword()) :: :ok
  defp log_dht_peers_found(hash_hex, peers, delay_ms, opts \\ []) do
    deep? = Keyword.get(opts, :deep, false)
    deep_tag = if deep?, do: " deep=true", else: ""

    Logger.info(
      "[magnet_fetch] dht_peers hash=#{hash_hex} count=#{length(peers)} delay_ms=#{delay_ms}#{deep_tag}"
    )
  end

  @spec ensure_dht_bg_table() :: :ok
  defp ensure_dht_bg_table do
    case :ets.info(@dht_bg_table) do
      :undefined ->
        :ets.new(@dht_bg_table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc false
  @spec take_background_dht_peers(Torrent.hash()) :: [Peer.t()]
  def take_background_dht_peers(hash) when is_binary(hash) do
    ensure_dht_bg_table()

    case :ets.lookup(@dht_bg_table, hash) do
      [{^hash, {:done, peers}}] when is_list(peers) ->
        :ets.delete(@dht_bg_table, hash)
        peers

      _ ->
        []
    end
  end

  @spec maybe_spawn_dht_deep_background(Torrent.hash()) :: :ok
  defp maybe_spawn_dht_deep_background(hash) when is_binary(hash) do
    ensure_dht_bg_table()

    case :ets.lookup(@dht_bg_table, hash) do
      [{^hash, :pending}] ->
        :ok

      _ ->
        :ets.insert(@dht_bg_table, {hash, :pending})
        hash_hex = Torrent.hex_encoded_hash(hash)

        Task.start(fn ->
          peers = dht_peers_deep_retry(hash)

          if peers != [] do
            Logger.info(
              "[magnet_fetch] dht_background_peers hash=#{hash_hex} count=#{length(peers)}"
            )
          end

          :ets.insert(@dht_bg_table, {hash, {:done, peers}})
        end)

        :ok
    end
  end

  @doc false
  @spec dht_background_pending?(Torrent.hash()) :: boolean()
  def dht_background_pending?(hash) when is_binary(hash) do
    ensure_dht_bg_table()

    case :ets.lookup(@dht_bg_table, hash) do
      [{^hash, :pending}] -> true
      _ -> false
    end
  end

  @spec tracker_await_timeout_ms(Magnet.t()) :: pos_integer()
  def tracker_await_timeout_ms(%Magnet{trackers: trackers}) do
    batches = div(max(length(trackers), 1) - 1, @tracker_max_concurrency) + 1
    min(120_000, batches * @tracker_task_timeout_ms + 5_000)
  end

  @spec await_dht_peers(Task.t() | nil) :: [Peer.t()]
  defp await_dht_peers(nil), do: []

  defp await_dht_peers(task) do
    timeout = dht_await_timeout_ms()
    Task.await(task, timeout)
  catch
    :exit, _ ->
      Logger.warning("[magnet_fetch] dht_discovery_timeout timeout_ms=#{dht_await_timeout_ms()}")
      []
  end

  @spec dht_await_timeout_ms() :: pos_integer()
  defp dht_await_timeout_ms do
    # Quick retries only — deep retry runs inline when trackers are empty, or in
    # background when tracker peers already unblock the round.
    Enum.sum(@dht_retry_delays_ms) +
      length(@dht_retry_delays_ms) * DHTConfig.lookup_timeout_ms() + 5_000
  end

  @spec collect_tracker_peers(Magnet.t(), keyword()) :: {[Peer.t()], [String.t()]}
  defp collect_tracker_peers(%Magnet{} = magnet, stats) do
    trackers = Enum.uniq(magnet.trackers)

    peers =
      trackers
      |> Task.async_stream(
        fn tracker -> announce_tracker(tracker, magnet.hash, stats) end,
        max_concurrency: @tracker_max_concurrency,
        ordered: false,
        timeout: @magnet_tracker_task_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, peers} when is_list(peers) -> peers
        _ -> []
      end)

    {peers, trackers}
  end

  @spec announce_tracker(String.t(), Torrent.hash(), keyword()) :: [Peer.t()]
  defp announce_tracker(tracker, hash, stats) do
    case Tracker.request!(tracker, hash, stats, @tracker_request_opts) do
      %Tracker.Response{peers: peers} ->
        peers

      %Tracker.Error{} = error ->
        log_tracker_error(tracker, error)
        []

      _ ->
        []
    end
  rescue
    exception ->
      Logger.warning(
        "magnet tracker announce crashed tracker=#{tracker} exception=#{Exception.message(exception)}"
      )

      []
  end

  @spec announce_stopped_impl(Torrent.hash(), [String.t()]) :: :ok
  defp announce_stopped_impl(_hash, []), do: :ok

  defp announce_stopped_impl(hash, trackers) do
    stats = [uploaded: 0, downloaded: 0, left: 0, event: Torrent.stopped()]

    trackers
    |> Enum.uniq()
    |> Task.async_stream(
      fn tracker -> announce_tracker_stopped(tracker, hash, stats) end,
      max_concurrency: @tracker_max_concurrency,
      ordered: false,
      timeout: @tracker_task_timeout_ms,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  @spec announce_tracker_stopped(String.t(), Torrent.hash(), keyword()) :: :ok
  defp announce_tracker_stopped(tracker, hash, stats) do
    case Tracker.request!(tracker, hash, stats, @tracker_request_opts) do
      %Tracker.Response{} ->
        :ok

      %Tracker.Error{} = error ->
        log_tracker_error(tracker, error)
        :ok

      _ ->
        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "magnet tracker stopped announce crashed tracker=#{tracker} exception=#{Exception.message(exception)}"
      )

      :ok
  end

  @spec dht_peers(Torrent.hash()) :: [Peer.t()]
  defp dht_peers(hash) do
    case DHT.get_peers(hash) do
      {:ok, peers} -> peers
      _ -> []
    end
  end

  @spec merge_metadata_unavailable_errors(term(), term()) ::
          {:error, {:metadata_unavailable, [term()]}}
  defp merge_metadata_unavailable_errors(
         {:metadata_unavailable, swarm_failures},
         :metadata_unavailable
       )
       when is_list(swarm_failures) do
    failures =
      (swarm_failures ++ [:metadata_unavailable])
      |> Enum.uniq()

    {:error, {:metadata_unavailable, failures}}
  end

  defp merge_metadata_unavailable_errors(_swarm_reason, :metadata_unavailable) do
    {:error, {:metadata_unavailable, [:metadata_unavailable]}}
  end

  @spec fetch_metadata(Magnet.t(), [Peer.t()], [String.t()]) ::
          {:ok, Path.t(), [String.t()], boolean()} | {:error, term()}
  defp fetch_metadata(%Magnet{} = magnet, peers, announced_trackers) do
    hash_hex = Torrent.hex_encoded_hash(magnet.hash)
    peer_batch = peers |> shuffle() |> Enum.take(@max_peers)
    slots = min(length(peer_batch), @max_connections)

    :ok = Magnet.Fetcher.ConnectionLimit.acquire(slots)

    result =
      try do
        peer_batch
        |> Task.async_stream(
          fn peer -> fetch_metadata_from_peer(magnet, peer, peers) end,
          max_concurrency: @max_connections,
          ordered: false,
          timeout: metadata_peer_timeout_ms(),
          on_timeout: :kill_task
        )
        |> Enum.reduce_while(nil, fn
          {:ok, {:ok, path, private?}}, _acc ->
            {:halt, {:ok, path, private?}}

          {:ok, {:error, :info_hash_mismatch}}, _acc ->
            {:halt, {:error, :info_hash_mismatch}}

          _, acc ->
            {:cont, acc}
        end)
      after
        Magnet.Fetcher.ConnectionLimit.release(slots)
      end

    case result do
      {:ok, path, private?} ->
        Logger.info("[magnet_fetch] metadata_verified hash=#{hash_hex}")
        {:ok, path, announced_trackers, private?}

      {:error, :info_hash_mismatch} = error ->
        error

      nil ->
        Logger.warning("[magnet_fetch] metadata_unavailable hash=#{hash_hex}")
        {:error, :metadata_unavailable}
    end
  end

  @doc false
  @spec fetch_metadata_from_peer_for_test(Magnet.t(), Peer.t(), [Peer.t()]) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  def fetch_metadata_from_peer_for_test(magnet, primary, all_peers),
    do: fetch_metadata_from_peer(magnet, primary, all_peers)

  @spec fetch_metadata_from_peer(Magnet.t(), Peer.t(), [Peer.t()]) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  defp fetch_metadata_from_peer(%Magnet{} = magnet, %Peer{} = primary, all_peers) do
    peer_pool =
      all_peers
      |> List.delete(primary)
      |> then(&[primary | &1])
      |> shuffle()
      |> Enum.take(@connection_pool_size)

    with {:ok, connections} <- open_connection_pool(magnet, peer_pool) do
      try do
        with {:ok, metadata_blob} <- download_pieces(connections, magnet.hash),
             {:ok, info, blob} <-
               Magnet.UtMetadata.decode_and_verify_info(metadata_blob, magnet.hash),
             {:ok, path} <- write_torrent(magnet, blob) do
          {:ok, path, Magnet.private?(info)}
        else
          {:error, :info_hash_mismatch} ->
            Logger.warning("magnet metadata failed info-hash verification")
            {:error, :info_hash_mismatch}

          {:error, _} = error ->
            error
        end
      after
        Enum.each(connections, &Magnet.Connection.close/1)
      end
    end
  end

  @spec open_connection_pool(Magnet.t(), [Peer.t()]) ::
          {:ok, [Magnet.Connection.t()]} | {:error, term()}
  defp open_connection_pool(%Magnet{} = magnet, peers) do
    connections =
      peers
      |> Enum.reduce([], fn %Peer{} = peer, acc ->
        case Magnet.Connection.open(peer, magnet.hash) do
          {:ok, conn} -> [conn | acc]
          {:error, _} -> acc
        end
      end)

    if connections == [], do: {:error, :no_connections}, else: {:ok, connections}
  end

  @spec download_pieces([Magnet.Connection.t()], Torrent.hash()) ::
          {:ok, binary()} | {:error, term()}
  defp download_pieces(connections, hash) do
    case initial_piece_state(connections) do
      {:error, _} = error ->
        error

      {metadata_size, pieces} ->
        piece_count = Magnet.UtMetadata.piece_count(metadata_size)
        hash_hex = Torrent.hex_encoded_hash(hash)

        Logger.info(
          "[magnet_fetch] metadata_pieces hash=#{hash_hex} total=#{piece_count} have=#{map_size(pieces)} size=#{metadata_size}"
        )

        missing =
          0..(piece_count - 1)
          |> Enum.reject(&Map.has_key?(pieces, &1))

        with {:ok, all_pieces} <-
               fetch_missing_pieces(connections, metadata_size, pieces, missing, hash) do
          Logger.info(
            "[magnet_fetch] metadata_pieces_done hash=#{hash_hex} pieces=#{map_size(all_pieces)}"
          )

          Magnet.UtMetadata.assemble_pieces(all_pieces, metadata_size)
        end
    end
  end

  @spec initial_piece_state([Magnet.Connection.t()]) ::
          {pos_integer(), %{non_neg_integer() => binary()}} | {:error, term()}
  defp initial_piece_state(connections) do
    case infer_metadata_size(connections) do
      size when is_integer(size) and size > 0 ->
        {size, %{}}

      _ ->
        case fetch_piece_from_any(connections, 0) do
          {:ok, {0, data, total_size}} -> {total_size, %{0 => data}}
          {:error, _} = error -> error
        end
    end
  end

  @spec infer_metadata_size([Magnet.Connection.t()]) :: pos_integer() | nil
  defp infer_metadata_size(connections) do
    connections
    |> Enum.find_value(fn
      %Magnet.Connection{metadata_size: size} when is_integer(size) and size > 0 ->
        size

      %Magnet.Connection{ltep: ltep} when not is_nil(ltep) ->
        case Peer.LTEP.Session.peer_handshake(ltep).metadata_size do
          size when is_integer(size) and size > 0 -> size
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  @spec fetch_missing_pieces(
          [Magnet.Connection.t()],
          pos_integer(),
          %{non_neg_integer() => binary()},
          [non_neg_integer()],
          Torrent.hash()
        ) :: {:ok, %{non_neg_integer() => binary()}} | {:error, term()}
  defp fetch_missing_pieces(_connections, _total_size, pieces, [], _hash), do: {:ok, pieces}

  defp fetch_missing_pieces(connections, total_size, pieces, [index | rest], hash) do
    case fetch_piece_from_any(connections, index) do
      {:ok, {^index, data, ^total_size}} ->
        if rem(index + 1, 4) == 0 or rest == [] do
          Logger.debug(
            "[magnet_fetch] metadata_piece hash=#{Torrent.hex_encoded_hash(hash)} index=#{index} remaining=#{length(rest)}"
          )
        end

        fetch_missing_pieces(connections, total_size, Map.put(pieces, index, data), rest, hash)

      {:ok, {_index, _data, other_size}} ->
        {:error, {:metadata_size_mismatch, other_size, total_size}}

      {:error, :all_rejected} ->
        {:error, :metadata_unavailable}

      {:error, _} = error ->
        error
    end
  end

  @spec fetch_piece_from_any([Magnet.Connection.t()], non_neg_integer()) ::
          {:ok, {non_neg_integer(), binary(), pos_integer()}} | {:error, term()}
  defp fetch_piece_from_any(connections, piece_index) do
    connections
    |> shuffle()
    |> Enum.reduce_while({:error, :all_rejected, nil}, fn conn, acc ->
      case Magnet.Connection.request_piece(conn, piece_index) do
        {:ok, data, total_size} ->
          {:halt, {:ok, {piece_index, data, total_size}}}

        {:reject, ^piece_index} ->
          {:cont, acc}

        {:error, reason} ->
          acc = {:error, :all_rejected, reason}

          if retryable_piece_error?(reason),
            do: {:cont, acc},
            else: {:halt, {:error, reason}}
      end
    end)
    |> finalize_piece_attempt()
  end

  @spec finalize_piece_attempt(
          {:ok, {non_neg_integer(), binary(), pos_integer()}}
          | {:error, :all_rejected, term() | nil}
        ) :: {:ok, {non_neg_integer(), binary(), pos_integer()}} | {:error, term()}
  defp finalize_piece_attempt({:ok, _} = ok), do: ok

  defp finalize_piece_attempt({:error, :all_rejected, nil}), do: {:error, :metadata_unavailable}

  defp finalize_piece_attempt({:error, :all_rejected, reason}),
    do: {:error, reason || :metadata_unavailable}

  @retryable_piece_errors [:closed, :choked, :timeout, :einval, :enotconn, :error]

  @spec retryable_piece_error?(term()) :: boolean()
  defp retryable_piece_error?(reason), do: reason in @retryable_piece_errors

  @spec shuffle(list()) :: list()
  defp shuffle(list) do
    list
    |> Enum.with_index()
    |> Enum.sort_by(fn {_item, index} -> :rand.uniform() + index / 1_000_000 end)
    |> Enum.map(&elem(&1, 0))
  end

  @spec write_torrent(Magnet.t(), binary()) :: {:ok, Path.t()} | {:error, term()}
  defp write_torrent(%Magnet{} = magnet, info_blob) when is_binary(info_blob) do
    path = torrent_path(magnet.hash)
    File.mkdir_p!(Path.dirname(path))
    torrent = Magnet.build_torrent!(magnet, info_blob)
    :ok = File.write(path, torrent)
    {:ok, path}
  end

  @spec torrent_path(Torrent.hash()) :: Path.t()
  def torrent_path(hash) do
    id = Torrent.hex_encoded_hash(hash)
    Path.join([System.tmp_dir!(), "elixir_torrent", "magnets", "#{id}.torrent"])
  end

  @spec log_tracker_error(String.t(), Tracker.Error.t()) :: :ok
  defp log_tracker_error(tracker, %Tracker.Error{reason: reason}) do
    Logger.warning("magnet tracker announce failed tracker=#{tracker} reason=#{inspect(reason)}")
  end
end

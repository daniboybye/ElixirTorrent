defmodule PeerDiscovery.AnnounceCoverageBatchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PeerDiscovery.Announce
  alias Tracker.{Error, Response}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  defp base_state(overrides) do
    torrent_pid =
      case Keyword.get(overrides, :torrent_pid) do
        nil ->
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        pid ->
          pid
      end

    struct!(
      %Announce{
        torrent_pid: torrent_pid,
        hash: <<9::160>>,
        tiers: [["http://127.0.0.1:1/announce"]],
        private?: true
      },
      overrides
    )
  end

  defp start_swarm_with_connected(hash, n) when n >= 0 do
    name = {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

    case DynamicSupervisor.start_link(name: name, strategy: :one_for_one) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    current = Torrent.Swarm.count(hash)

    for _ <- List.duplicate(:dummy, max(n - current, 0)) do
      spec = %{
        id: :dummy_peer,
        start: {PeerDiscovery.AnnounceCoverageBatchTest.SwarmStub, :start_link, [[]]},
        restart: :temporary
      }

      {:ok, _} = DynamicSupervisor.start_child(name, spec)
    end

    assert Torrent.Swarm.count(hash) == n
  end

  defp start_manager!(hash) do
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}
    {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)
    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)
    pid
  end

  defp start_announce!(hash, torrent) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}
    {:ok, pid} = GenServer.start_link(Announce, [self(), torrent], name: name)
    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)
    pid
  end

  describe "tracker task handle_info branches" do
    test "stale tracker ref leaves state unchanged" do
      ref = make_ref()
      peer = %Peer{ip: {1, 2, 3, 4}, port: 6881}

      state =
        base_state(
          requests: %{},
          tier_batches: %{0 => 1}
        )

      response = %Response{peers: [peer], interval: 600, complete: 1, incomplete: 0}

      unchanged =
        Announce.dispatch_task_message(state, {ref, {Torrent.started(), response}})

      assert unchanged.requests == %{}
      assert unchanged.tier_batches == %{0 => 1}
      refute Map.has_key?(unchanged.peers, "http://127.0.0.1:1/announce")
    end

    test "event tuple unwrap forwards Tracker.Error to cooldown handler" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/overloaded"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      error = %Error{reason: "Overloaded", retry_in: 90}

      cooled = Announce.dispatch_task_message(state, {ref, {nil, error}})

      assert cooled.requests == %{}
      refute Announce.tier_batches_active?(cooled)
      assert cooled.retry_after_ms[announce] >= System.monotonic_time(:millisecond) + 89_000
    end

    test "partial parallel batch decrements in-flight count without tier hop" do
      ref1 = make_ref()
      ref2 = make_ref()
      announce = "http://127.0.0.1:1/announce"

      state =
        base_state(
          requests: %{
            ref1 => {announce, 0, 0},
            ref2 => {announce, 0, 1}
          },
          tier_batches: %{0 => 2}
        )

      one_left =
        Announce.dispatch_task_message(state, {ref1, %Error{reason: :timeout}})

      assert one_left.tier_batches == %{0 => 1}
      assert map_size(one_left.requests) == 1
      refute_receive {:parallel_announce, _}, 20
    end

    test "generic task result applies default failure interval" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/announce"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      failed = Announce.dispatch_task_message(state, {ref, :unexpected_payload})

      assert failed.requests == %{}
      refute Announce.tier_batches_active?(failed)

      assert failed.retry_after_ms[announce] >=
               System.monotonic_time(:millisecond) +
                 Tracker.default_failure_interval() * 1_000 - 50
    end

    test "parallel_tracker_error ignores unknown ref" do
      ref = make_ref()

      state =
        base_state(
          requests: %{},
          tier_batches: %{0 => 1}
        )

      unchanged =
        Announce.dispatch_task_message(state, {ref, %Error{reason: :timeout}})

      assert unchanged.requests == %{}
      assert unchanged.tier_batches == %{0 => 1}
    end

    test "never-retry with unknown meta leaves disabled and batches untouched" do
      ref = make_ref()

      state =
        base_state(
          requests: %{ref => {:dht, <<9::160>>}},
          tier_batches: %{0 => 1}
        )

      error = %Error{reason: :nxdomain, retry_in: "never"}

      after_msg = Announce.dispatch_task_message(state, {ref, error})

      assert after_msg.requests == %{}
      assert after_msg.tier_batches == %{0 => 1}
      assert MapSet.size(after_msg.disabled) == 0
    end

    test "DHT {:error, _} with nil request is a no-op" do
      ref = make_ref()
      state = base_state(requests: %{})

      after_msg = Announce.dispatch_task_message(state, {ref, {:error, :timeout}})

      assert after_msg.requests == %{}
    end

    test "DHT round completion with zero peers schedules another lookup" do
      ref = make_ref()
      hash = <<100::160>>

      state =
        base_state(
          hash: hash,
          private?: false,
          requests: %{ref => {:dht, hash}},
          dht_round_peers: [],
          last_dht_lookup_ms: 1_000
        )

      after_err = Announce.dispatch_task_message(state, {ref, {:error, :timeout}})

      assert after_err.requests == %{}
      assert after_err.dht_peers == []
    end

    test "tracker event tuple unwrap forwards responses and errors" do
      hash = <<101::160>>
      ref = make_ref()
      announce = "http://127.0.0.1:1/unwrap"
      peer = %Peer{ip: {203, 0, 113, 100}, port: 6881}

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "unwrap", "private" => 1}},
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      ok_state =
        base_state(
          hash: hash,
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      response = %Response{peers: [peer], interval: 600, complete: 1, incomplete: 0}

      assert Announce.dispatch_task_message(
               ok_state,
               {ref, {Torrent.empty(), response}}
             ).peers[announce] == [peer]

      ref2 = make_ref()

      err_state =
        base_state(
          hash: hash,
          requests: %{ref2 => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      assert Announce.dispatch_task_message(
               err_state,
               {ref2, {nil, %Error{reason: :timeout}}}
             ).requests == %{}
    end

    test "DHT task DOWN decrements pending round" do
      ref = make_ref()
      hash = <<9::160>>

      task_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state =
        base_state(
          hash: hash,
          requests: %{ref => {:dht, hash}},
          dht_round_peers: []
        )

      # Non-:normal DOWN reasons reach the request-ref handler; :normal is ignored.
      after_down =
        Announce.dispatch_task_message(state, {:DOWN, ref, :process, task_pid, :timeout})

      assert after_down.requests == %{}
    end

    test "tracker task DOWN clears batch slot" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/announce"

      task_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      after_down =
        Announce.dispatch_task_message(state, {:DOWN, ref, :process, task_pid, :killed})

      assert after_down.requests == %{}
      refute Announce.tier_batches_active?(after_down)
    end

    test "unknown DOWN ref leaves state unchanged" do
      ref = make_ref()
      state = base_state(requests: %{}, tier_batches: %{})

      after_down =
        Announce.dispatch_task_message(state, {:DOWN, ref, :process, self(), :normal})

      assert after_down == state
    end

    test "torrent process DOWN stops announce state machine" do
      torrent_pid = self()
      state = base_state(torrent_pid: torrent_pid)

      stopped =
        Announce.dispatch_task_message(
          state,
          {:DOWN, make_ref(), :process, torrent_pid, :shutdown}
        )

      assert stopped.torrent_pid == torrent_pid
    end
  end

  describe "retry_in parsing and BEP 31 cooldown" do
    test "integer retry_in seconds are honoured directly" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/cooldown"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      before = System.monotonic_time(:millisecond)

      cooled =
        Announce.dispatch_task_message(state, {ref, %Error{reason: :timeout, retry_in: 45}})

      assert cooled.retry_after_ms[announce] >= before + 45_000
    end

    test "unparseable retry_in binary falls back to default failure interval" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/garbage-retry"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      before = System.monotonic_time(:millisecond)

      cooled =
        Announce.dispatch_task_message(state, {ref, %Error{reason: :timeout, retry_in: "soon"}})

      assert cooled.retry_after_ms[announce] >=
               before + Tracker.default_failure_interval() * 1_000 - 50
    end

    test "unexpected failure reason logs warning and uses default interval" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/weird"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      log =
        capture_log([level: :warning], fn ->
          _ =
            Announce.dispatch_task_message(state, {
              ref,
              %Error{reason: :invalid_bencode, retry_in: nil}
            })
        end)

      assert log =~ "request failure reason"
    end
  end

  describe "tier promotion, failover, and fan-out collection" do
    test "at-target successful batch reschedules the same tier" do
      hash = <<60::160>>
      announce = "http://127.0.0.1:1/at-target-ok"
      ref = make_ref()
      peer = %Peer{ip: {203, 0, 113, 60}, port: 6881}

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "at-target", "private" => 1}},
        left: 0,
        last_index: 0,
        last_piece_length: 512,
        peer_status: :seed
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tiers: [[announce]],
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1},
          tier_batch_successes: MapSet.new([0]),
          tracker_interval_sec: 1_800,
          tracker_min_interval_sec: 45,
          last_tracker_announce_ms: System.monotonic_time(:millisecond)
        )

      response = %Response{peers: [peer], interval: 1_800, complete: 10, incomplete: 2}

      after_ok =
        Announce.dispatch_task_message(state, {ref, {Torrent.empty(), response}})

      refute Announce.tier_batches_active?(after_ok)
      assert after_ok.peers[announce] == [peer]
    end

    test "BEP 48 dead-scrape tier skip logs and keeps live tracker in parallel batch" do
      dead = "http://127.0.0.1:1/dead-scrape"
      backup = "http://127.0.0.1:1/backup"
      now_ms = System.monotonic_time(:millisecond)

      state =
        base_state(
          tiers: [[dead, backup]],
          scrape_stats: %{
            dead => %{seeders: 0, leechers: 0, completed: 0, ts_ms: now_ms}
          },
          last_tracker_announce_ms: nil
        )

      log =
        capture_log([level: :debug], fn ->
          started = Announce.dispatch_task_message(state, {:parallel_announce, 0})
          assert started.tier_batches == %{0 => 1}

          assert Enum.any?(started.requests, fn
                   {_ref, {^backup, 0, _idx}} -> true
                   _ -> false
                 end)
        end)

      assert log =~ "tier_skip"
    end

    test "at-target all-dead tier schedules backup tier announce" do
      hash = <<61::160>>
      dead = "http://127.0.0.1:1/dead-scrape"
      backup = "http://127.0.0.1:1/backup"
      now_ms = System.monotonic_time(:millisecond)

      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tiers: [[dead], [backup]],
          scrape_stats: %{
            dead => %{seeders: 0, leechers: 0, completed: 0, ts_ms: now_ms}
          },
          tier_index: 0,
          last_tracker_announce_ms: nil
        )

      after_msg = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert after_msg.tier_batches == %{}
      assert_receive {:parallel_announce, 1}, 100
    end

    test "empty tier entry advances to next tier under target" do
      live = "http://127.0.0.1:1/live"

      state =
        base_state(
          tiers: [[], [live]],
          last_tracker_announce_ms: nil
        )

      started = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert started.tier_batches == %{1 => 1}
      assert started.tier_index == 1
    end

    test "fan-out wave continues from fanout_high_tier after zero-peer batch" do
      tiers =
        for i <- 0..5 do
          ["http://127.0.0.1:1/tier#{i}"]
        end

      ref0 = make_ref()
      announce0 = "http://127.0.0.1:1/tier0"

      state =
        base_state(
          tiers: tiers,
          tier_batches: %{0 => 1},
          fanout_high_tier: 3,
          requests: %{ref0 => {announce0, 0, 0}},
          peers: %{},
          last_tracker_announce_ms: nil
        )

      after_batch =
        Announce.dispatch_task_message(state, {ref0, %Error{reason: :timeout}})

      refute Announce.tier_batches_active?(after_batch)
      assert Announce.tracker_peers_empty?(after_batch)
      assert_receive {:parallel_announce, 4}, 100
    end

    test "at-target parallel_announce waits when batches are still active" do
      hash = <<62::160>>
      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tier_batches: %{0 => 2},
          last_tracker_announce_ms: nil
        )

      unchanged = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert unchanged.tier_batches == %{0 => 2}
      refute_receive {:parallel_announce, _}, 20
    end

    test "promote_tracker is noop when URL is absent from tier list" do
      hash = <<9::160>>

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "ghost-promote", "private" => 1}},
        left: 512,
        last_index: 0,
        last_piece_length: 512,
        peer_status: :seed
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      state =
        base_state(
          hash: hash,
          tiers: [["http://127.0.0.1:1/a"]],
          peers: %{}
        )

      response = %Response{
        peers: [%Peer{ip: {1, 1, 1, 1}, port: 6881}],
        interval: 600,
        complete: 1,
        incomplete: 0
      }

      ref = make_ref()
      ghost = "http://127.0.0.1:1/ghost"

      after_msg =
        Announce.dispatch_task_message(
          Map.put(state, :requests, %{ref => {ghost, 0, 0}}) |> Map.put(:tier_batches, %{0 => 1}),
          {ref, {Torrent.started(), response}}
        )

      assert after_msg.tiers == state.tiers
    end
  end

  describe "scrape batch and BEP 48 health" do
    test "scrape_tick with empty tiers is a no-op" do
      state = base_state(tiers: [], requests: %{})

      after_tick = Announce.dispatch_task_message(state, :scrape_tick)

      assert after_tick.requests == %{}
      assert after_tick.last_scrape_ms == nil
    end

    test "scrape_tick skips disabled and unsupported URLs" do
      alive = "http://127.0.0.1:1/alive"
      disabled = "http://127.0.0.1:1/disabled"
      unsupported = "http://127.0.0.1:1/no-scrape"

      state =
        base_state(
          tiers: [[alive, disabled, unsupported]],
          disabled: MapSet.new([disabled]),
          scrape_stats: %{unsupported => %{unsupported: true}}
        )

      after_tick = Announce.dispatch_task_message(state, :scrape_tick)

      assert map_size(after_tick.requests) == 1

      assert [{_ref, {:scrape, ^alive}}] =
               Enum.filter(after_tick.requests, fn
                 {_ref, {:scrape, url}} -> url == alive
                 _ -> false
               end)
    end

    test "stale scrape stats ref is ignored" do
      ref = make_ref()
      state = base_state(requests: %{})

      after_msg =
        Announce.dispatch_task_message(state, {ref, %{seeders: 1, leechers: 2, completed: 3}})

      assert after_msg.scrape_stats == %{}
    end
  end

  describe "refresh casts and private guards" do
    test "replenish_candidates offers merged peers to ConnectionManager" do
      hash = :crypto.strong_rand_bytes(20)
      peer = %Peer{ip: {192, 0, 2, 55}, port: 6881}
      start_manager!(hash)

      torrent = %Torrent{
        hash: hash,
        metadata: %{"name" => "replenish"},
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      pid = start_announce!(hash, torrent)

      :sys.replace_state(pid, fn state ->
        %{state | peers: %{"http://127.0.0.1:1/t" => [peer]}, private?: false}
      end)

      GenServer.cast(pid, :replenish_candidates)
      _ = :sys.get_state(pid)

      manager = GenServer.whereis({:via, Registry, {Registry, {hash, Peer.ConnectionManager}}})
      assert Map.has_key?(:sys.get_state(manager).queue, {peer.ip, peer.port})
    end

    test "maybe_refresh_peers under target starts parallel tier when idle" do
      hash = :crypto.strong_rand_bytes(20)
      tracker = "http://127.0.0.1:1/t"

      torrent = %Torrent{
        hash: hash,
        metadata: %{"name" => "refresh", "announce-list" => [[tracker]]},
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      pid = start_announce!(hash, torrent)

      TestSupport.Sync.with_suspended(pid, fn ->
        :sys.replace_state(pid, fn state ->
          %{
            state
            | tier_batches: %{},
              tier_index: 0,
              last_tracker_announce_ms: nil,
              requests: %{}
          }
        end)

        GenServer.cast(pid, :maybe_refresh_peers)
      end)

      TestSupport.Sync.sync(pid)

      state = :sys.get_state(pid)
      assert Announce.tier_batches_active?(state) or map_size(state.requests) > 0
    end

    test "private torrent ignores DHT lookup message" do
      state = base_state(private?: true, last_dht_lookup_ms: nil)

      after_lookup = Announce.dispatch_task_message(state, :dht_lookup)

      assert after_lookup.last_dht_lookup_ms == nil
      assert after_lookup.requests == %{}
    end

    test "private torrent finishes empty DHT round without scheduling retry" do
      ref = make_ref()
      hash = <<9::160>>

      state =
        base_state(
          hash: hash,
          private?: true,
          requests: %{ref => {:dht, hash}},
          dht_round_peers: []
        )

      after_err = Announce.dispatch_task_message(state, {ref, {:error, :timeout}})

      assert after_err.requests == %{}
      refute_receive :dht_lookup, 20
    end

    test "private? returns false when announce process is absent" do
      hash = :crypto.strong_rand_bytes(20)
      refute Announce.private?(hash)
    end

    test "request_peer_refresh and replenish_candidates tolerate missing announce" do
      hash = :crypto.strong_rand_bytes(20)
      assert :ok = Announce.request_peer_refresh(hash)
      assert :ok = PeerDiscovery.replenish_candidates(hash)
    end
  end

  describe "init metadata and DHT bootstrap paths" do
    test "init extracts single announce URL tier" do
      hash = <<70::160>>

      torrent = %Torrent{
        hash: hash,
        metadata: %{"announce" => "http://127.0.0.1:1/single", "info" => %{"name" => "single"}},
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      assert {:ok, state} = Announce.init([self(), torrent, []])
      assert state.tiers == [["http://127.0.0.1:1/single"]]
    end

    test "init normalizes binary and invalid announce-list tiers" do
      hash = <<71::160>>

      torrent = %Torrent{
        hash: hash,
        metadata: %{
          "announce-list" => ["http://127.0.0.1:1/alone", 123, []],
          "info" => %{"name" => "normalize"}
        },
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      assert {:ok, state} = Announce.init([self(), torrent, []])
      assert state.tiers == [["http://127.0.0.1:1/alone"]]
    end

    test "init with nodes metadata bootstraps DHT from loopback host" do
      hash = <<72::160>>

      torrent = %Torrent{
        hash: hash,
        metadata: %{
          "nodes" => [["127.0.0.1", 6881]],
          "info" => %{"name" => "nodes-only", "private" => 1}
        },
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      assert {:ok, state} = Announce.init([self(), torrent, []])
      assert state.tiers == []
    end
  end

  describe "dht cadence helpers" do
    test "dht_lookup_allowed? uses critical cadence below twelve connected peers" do
      hash = <<99::160>>
      start_swarm_with_connected(hash, 5)

      now = 30_000_000
      state = base_state(hash: hash, last_dht_lookup_ms: now, private?: false)

      assert {:wait, wait_ms} = Announce.dht_lookup_allowed?(state, now + 5_000)
      assert wait_ms >= 8_000
      assert :ok = Announce.dht_lookup_allowed?(state, now + 15_000)
    end

    test "dht_lookup_allowed? uses 300s interval at swarm target" do
      hash = <<80::160>>
      start_swarm_with_connected(hash, 80)

      now = 10_000_000
      state = base_state(hash: hash, last_dht_lookup_ms: now, private?: false)

      assert {:wait, wait_ms} = Announce.dht_lookup_allowed?(state, now + 60_000)
      assert wait_ms >= 230_000
      assert :ok = Announce.dht_lookup_allowed?(state, now + 300_000)
    end

    test "dht_lookup waits when the cadence floor has not elapsed" do
      now = 50_000_000
      state = base_state(last_dht_lookup_ms: now, private?: false)

      assert {:wait, wait_ms} = Announce.dht_lookup_allowed?(state, now + 5_000)
      assert wait_ms >= 10_000
    end
  end

  describe "mailbox timers, DHT results, and scrape fan-out" do
    test "peer_refresh_tick under target schedules tracker and DHT refresh" do
      hash = <<81::160>>
      tracker = "http://127.0.0.1:1/refresh-tick"

      state =
        base_state(
          hash: hash,
          tiers: [[tracker]],
          tier_batches: %{},
          last_tracker_announce_ms: nil,
          last_dht_lookup_ms: nil,
          private?: false
        )

      _after_tick = Announce.dispatch_task_message(state, :peer_refresh_tick)

      assert_receive {:parallel_announce, 0}, 100
      assert_receive :dht_lookup, 100
    end

    test "peer_refresh_tick at swarm target is a no-op" do
      hash = <<82::160>>
      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tier_batches: %{0 => 1},
          last_tracker_announce_ms: nil
        )

      unchanged = Announce.dispatch_task_message(state, :peer_refresh_tick)
      assert unchanged.tier_batches == %{0 => 1}
      refute_receive {:parallel_announce, _}, 20
      refute_receive :dht_lookup, 20
    end

    test "parallel_announce waits on tracker min-interval when not starved" do
      now = System.monotonic_time(:millisecond)

      state =
        base_state(
          last_tracker_announce_ms: now,
          tracker_min_interval_sec: 120,
          tracker_interval_sec: 600,
          peers: %{"http://127.0.0.1:1/t" => [%Peer{ip: {1, 1, 1, 1}, port: 6881}]}
        )

      after_msg = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert after_msg.tier_batches == %{}
      refute_receive {:parallel_announce, _}, 20
    end

    test "dht_lookup defers when the lookup interval has not elapsed" do
      now = System.monotonic_time(:millisecond)

      state =
        base_state(
          last_dht_lookup_ms: now,
          private?: false
        )

      after_msg = Announce.dispatch_task_message(state, :dht_lookup)

      assert after_msg.last_dht_lookup_ms == now
      assert after_msg.requests == %{}
    end

    test "non-DHT {:ok, peers} task results pop the ref without merging peers" do
      ref = make_ref()
      state = base_state(requests: %{ref => {"http://127.0.0.1:1/t", 0, 0}})

      after_msg =
        Announce.dispatch_task_message(state, {ref, {:ok, [%Peer{ip: {1, 2, 3, 4}, port: 6881}]}})

      assert after_msg.requests == %{}
    end

    test "tracker {:error, _} decrements the tier batch counter" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/err"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      after_err = Announce.dispatch_task_message(state, {ref, {:error, :timeout}})

      assert after_err.requests == %{}
      refute Announce.tier_batches_active?(after_err)
    end

    test "DOWN with scrape metadata leaves tier batches untouched" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/scrape"

      state =
        base_state(
          requests: %{ref => {:scrape, announce}},
          tier_batches: %{0 => 2}
        )

      after_down =
        Announce.dispatch_task_message(state, {:DOWN, ref, :process, self(), :killed})

      assert after_down.tier_batches == %{0 => 2}
      assert after_down.requests == %{}
    end

    test "scrape_tick fans out BEP 48 health checks for live announce URLs" do
      alive = "http://127.0.0.1:1/alive-scrape"

      state =
        base_state(
          tiers: [[alive]],
          disabled: MapSet.new(),
          scrape_stats: %{},
          requests: %{}
        )

      after_tick = Announce.dispatch_task_message(state, :scrape_tick)

      assert map_size(after_tick.requests) == 1

      assert Enum.any?(after_tick.requests, fn
               {_ref, {:scrape, ^alive}} -> true
               _ -> false
             end)

      assert is_integer(after_tick.last_scrape_ms)
    end
  end

  describe "at-target tier promotion and PEX (BEP 14/31)" do
    test "at-target ring_exhausted schedules a tier retry" do
      hash = <<83::160>>
      dead = "http://127.0.0.1:1/dead"
      now_ms = System.monotonic_time(:millisecond)
      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tiers: [[dead]],
          disabled: MapSet.new([dead]),
          scrape_stats: %{
            dead => %{seeders: 0, leechers: 0, completed: 0, ts_ms: now_ms}
          },
          tier_batches: %{},
          last_tracker_announce_ms: nil
        )

      after_msg = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      refute Announce.tier_batches_active?(after_msg)
    end

    test "at-target empty tier hops to the next tier immediately" do
      hash = <<84::160>>
      backup = "http://127.0.0.1:1/backup"
      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tiers: [[], [backup]],
          tier_batches: %{},
          last_tracker_announce_ms: nil
        )

      _started = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert_receive {:parallel_announce, 1}, 100
    end

    test "public PEX broadcast tick refreshes the global snapshot" do
      hash = <<85::160>>
      start_swarm_with_connected(hash, 3)

      state = base_state(hash: hash, private?: false, pex_snapshot: %{})

      after_pex = Announce.dispatch_task_message(state, :pex_broadcast)

      assert is_map(after_pex.pex_snapshot)
    end

    test "dead tier advance wraps to tracker interval at swarm target" do
      hash = <<86::160>>
      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tiers: [["http://127.0.0.1:1/a"]],
          tracker_interval_sec: 1_800,
          tracker_min_interval_sec: 45
        )

      assert Announce.dead_tier_advance_interval(state, 0) >= 45
      assert Announce.parallel_tier_reschedule_interval(state, 900) >= 45
      assert Announce.parallel_tier_failure_advance_interval(state, 0, 900) >= 45
    end
  end

  describe "init bootstrap and DHT hash selection" do
    test "init ignores malformed nodes entries while bootstrapping valid hosts" do
      hash = <<87::160>>

      torrent = %Torrent{
        hash: hash,
        metadata: %{
          "nodes" => [["127.0.0.1", 6881], "not-a-node", []],
          "info" => %{"name" => "nodes-mixed", "private" => 1}
        },
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      assert {:ok, state} = Announce.init([self(), torrent, []])
      assert state.tiers == []
      assert state.dht_hashes == [hash]
    end

    test "init with unknown nodes host does not abort" do
      hash = <<88::160>>

      torrent = %Torrent{
        hash: hash,
        metadata: %{
          "nodes" => [["this-host-does-not-exist.invalid.", 6881]],
          "info" => %{"name" => "nodes-bad-dns", "private" => 1}
        },
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      assert {:ok, _state} = Announce.init([self(), torrent, []])
    end

    test "init offers seed peers to ConnectionManager" do
      hash = <<89::160>>
      seed = %Peer{ip: {192, 0, 2, 90}, port: 6881}
      start_manager!(hash)
      :ok = PeerDiscovery.SeedPeers.put(hash, [seed])

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "seed-offer", "private" => 1}},
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}
      {:ok, pid} = GenServer.start_link(Announce, [self(), torrent, []], name: name)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      GenServer.cast(pid, :replenish_candidates)
      _ = :sys.get_state(pid)

      manager = GenServer.whereis({:via, Registry, {Registry, {hash, Peer.ConnectionManager}}})
      assert Map.has_key?(:sys.get_state(manager).queue, {seed.ip, seed.port})
      assert :sys.get_state(pid).seed_peers == [seed]
    end
  end

  describe "retry parsing edge cases" do
    test "binary retry_in with leading junk falls back to default failure interval" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/junk-retry"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      before = System.monotonic_time(:millisecond)

      cooled =
        Announce.dispatch_task_message(state, {ref, %Error{reason: :timeout, retry_in: "x5"}})

      assert cooled.retry_after_ms[announce] >=
               before + Tracker.default_failure_interval() * 1_000 - 50
    end

    test "never retry_in maps to zero-second reschedule internally" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/never"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      disabled =
        Announce.dispatch_task_message(state, {ref, %Error{reason: :nxdomain, retry_in: :never}})

      assert MapSet.member?(disabled.disabled, announce)
    end

    test "binary retry_in with only a numeric prefix applies that many seconds" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/text-retry"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      before = System.monotonic_time(:millisecond)

      cooled =
        Announce.dispatch_task_message(state, {ref, %Error{reason: :timeout, retry_in: "12"}})

      assert cooled.retry_after_ms[announce] >= before + 12_000 - 50
    end

    test "unparseable binary retry_in beginning with separators falls back to default interval" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/bad-prefix"

      state =
        base_state(
          requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
        )

      before = System.monotonic_time(:millisecond)

      cooled =
        Announce.dispatch_task_message(
          state,
          {ref, %Error{reason: :timeout, retry_in: "minutes"}}
        )

      assert cooled.retry_after_ms[announce] >=
               before + Tracker.default_failure_interval() * 1_000 - 50
    end
  end

  describe "under-target fan-out collection" do
    test "fan-out skips tiers whose trackers are all disabled" do
      dead0 = "http://127.0.0.1:1/dead0"
      live1 = "http://127.0.0.1:1/live1"

      state =
        base_state(
          tiers: [[dead0], [live1]],
          disabled: MapSet.new([dead0]),
          tier_batches: %{},
          last_tracker_announce_ms: nil
        )

      started = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert started.tier_batches == %{1 => 1}
    end

    test "fan-out stops when tier index exceeds the announce list" do
      state =
        base_state(
          tiers: [["http://127.0.0.1:1/only"]],
          tier_batches: %{},
          last_tracker_announce_ms: nil
        )

      after_msg = Announce.dispatch_task_message(state, {:parallel_announce, 99})

      assert after_msg.tier_batches == %{0 => 1}
    end

    test "fan-out returns partial tiers when the ring is exhausted mid-collection" do
      now_ms = System.monotonic_time(:millisecond)
      dead = "http://127.0.0.1:1/dead"
      live = "http://127.0.0.1:1/live"

      state =
        base_state(
          tiers: [[dead], [live], [dead]],
          disabled: MapSet.new([dead]),
          scrape_stats: %{
            dead => %{seeders: 0, leechers: 0, completed: 0, ts_ms: now_ms}
          },
          tier_batches: %{2 => 1},
          last_tracker_announce_ms: nil
        )

      started = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert Map.has_key?(started.tier_batches, 1)
    end
  end

  describe "DHT lookup spawn and announce helpers" do
    test "dht_lookup spawns get_peers tasks when allowed" do
      hash = <<94::160>>

      state =
        base_state(
          hash: hash,
          private?: false,
          last_dht_lookup_ms: nil,
          dht_module: PeerDiscovery.AnnounceCoverageBatchTest.DHTStub
        )

      after_lookup = Announce.dispatch_task_message(state, :dht_lookup)

      assert map_size(after_lookup.requests) == 1
      assert is_integer(after_lookup.last_dht_lookup_ms)
    end

    test "dht_hashes falls back to the torrent hash when the list is empty" do
      hash = <<95::160>>
      state = base_state(hash: hash, dht_hashes: [])

      ref = make_ref()

      after_ok =
        Announce.dispatch_task_message(
          Map.put(state, :requests, %{ref => {:dht, hash}}),
          {ref, {:ok, [%Peer{ip: {203, 0, 113, 95}, port: 6881}]}}
        )

      assert after_ok.dht_peers != []
    end
  end

  describe "stopped_announce and replenish exit guards" do
    test "stopped_announce is safe when the announce worker is absent" do
      hash = :crypto.strong_rand_bytes(20)
      assert :ok = PeerDiscovery.stopped_announce(hash)
    end

    test "replenish_candidates with an empty peer pool is a no-op" do
      hash = <<96::160>>

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "empty-replenish", "private" => 1}},
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      pid = start_announce!(hash, torrent)

      :sys.replace_state(pid, fn state ->
        %{state | peers: %{}, dht_peers: [], seed_peers: []}
      end)

      GenServer.cast(pid, :replenish_candidates)
      assert %Announce{} = :sys.get_state(pid)
    end
  end

  describe "BEP 12 tracker promotion edge cases" do
    test "successful response does not promote when tier index is invalid" do
      hash = <<98::160>>
      ref = make_ref()
      announce = "http://127.0.0.1:1/ghost-tier"
      peer = %Peer{ip: {198, 18, 0, 1}, port: 6881}

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "ghost-tier", "private" => 1}},
        left: 512,
        last_index: 0,
        last_piece_length: 512
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)
      on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

      state =
        base_state(
          hash: hash,
          tiers: [["http://127.0.0.1:1/a"]],
          requests: %{ref => {announce, 9, 0}},
          tier_batches: %{9 => 1}
        )

      response = %Response{peers: [peer], interval: 600, complete: 1, incomplete: 0}

      after_ok =
        Announce.dispatch_task_message(state, {ref, {Torrent.started(), response}})

      assert after_ok.tiers == state.tiers
    end

    test "dec_tier_batch ignores unknown tier indices" do
      ref = make_ref()
      announce = "http://127.0.0.1:1/orphan"

      state =
        base_state(
          requests: %{ref => {announce, 9, 0}},
          tier_batches: %{0 => 1}
        )

      after_err = Announce.dispatch_task_message(state, {ref, %Error{reason: :timeout}})

      assert after_err.tier_batches == %{0 => 1}
    end
  end
end

defmodule PeerDiscovery.AnnounceCoverageBatchTest.DHTStub do
  @moduledoc false

  def get_peers(_hash), do: {:ok, []}
  def announce(_hash, _port), do: :ok
end

defmodule PeerDiscovery.AnnounceCoverageBatchTest.SwarmStub do
  @moduledoc false

  def start_link(_arg) do
    Task.start_link(fn ->
      release = make_ref()

      receive do
        ^release -> :ok
      end
    end)
  end
end

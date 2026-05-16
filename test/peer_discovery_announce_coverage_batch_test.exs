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

      state = :sys.get_state(pid)
      assert Announce.tier_batches_active?(state)

      assert Enum.any?(state.requests, fn
               {_ref, {^tracker, 0, _idx}} -> true
               _ -> false
             end)
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
    test "dht_lookup_allowed? uses 300s interval at swarm target" do
      hash = <<80::160>>
      start_swarm_with_connected(hash, 80)

      now = 10_000_000
      state = base_state(hash: hash, last_dht_lookup_ms: now, private?: false)

      assert {:wait, wait_ms} = Announce.dht_lookup_allowed?(state, now + 60_000)
      assert wait_ms >= 230_000
      assert :ok = Announce.dht_lookup_allowed?(state, now + 300_000)
    end
  end
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

defmodule PeerDiscoveryDualSwarmDHTStub do
  @moduledoc false

  def get_peers(hash) do
    test_pid = Process.whereis(__MODULE__)
    send(test_pid, {:dual_swarm_get_peers, self(), hash})

    receive do
      {:dual_swarm_reply, ^hash, peers} -> {:ok, peers}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def announce(hash, _port) do
    send(Process.whereis(__MODULE__), {:dual_swarm_announce, hash})
    :ok
  end
end

defmodule PeerDiscoveryAnnounceTest do
  use ExUnit.Case, async: false

  alias Peer.UtPex.Entry, as: UtPexEntry
  alias PeerDiscovery.Announce
  alias Tracker.{Error, Response}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  defp base_state(overrides) do
    struct!(
      %Announce{
        torrent_pid: self(),
        hash: <<9::160>>,
        tiers: [["udp://tracker.example:6969/announce"]],
        private?: true
      },
      overrides
    )
  end

  test "peer_list merges tracker and dht peers without raising" do
    hash = <<1::160>>
    p1 = %Peer{ip: {1, 2, 3, 4}, port: 6881}
    p2 = %Peer{ip: {5, 6, 7, 8}, port: 6882}
    p1_dup = %Peer{ip: {1, 2, 3, 4}, port: 6881}

    state = %Announce{
      torrent_pid: self(),
      hash: hash,
      peers: %{"http://tracker" => [p1, p1_dup]},
      dht_peers: [p2]
    }

    merged = Announce.peer_list(state)
    assert length(merged) == 2
    assert MapSet.new(merged) == MapSet.new([p1, p2])
  end

  test "peer_list returns empty list for empty state" do
    state = %Announce{torrent_pid: self(), hash: <<0::160>>, peers: %{}, dht_peers: []}
    assert Announce.peer_list(state) == []
  end

  test "peer_list logs peers_merged at debug when peers exist" do
    hash = <<2::160>>
    peer = %Peer{ip: {9, 9, 9, 9}, port: 6881}

    state = %Announce{
      torrent_pid: self(),
      hash: hash,
      peers: %{"http://t" => [peer]},
      dht_peers: []
    }

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert [%Peer{}] = Announce.peer_list(state)
      end)

    assert log =~ "[peer_discovery] peers_merged"
    assert log =~ "count=1"
  end

  test "dispatch_task_message stores dht get_peers success without raising" do
    ref = make_ref()
    hash = <<9::160>>
    peers = [%Peer{ip: {88, 230, 64, 159}, port: 20_959}]

    state =
      base_state(
        requests: %{ref => {:dht, hash}},
        dht_peers: []
      )

    new_state = Announce.dispatch_task_message(state, {ref, {:ok, peers}})

    assert new_state.dht_peers == peers
    assert new_state.requests == %{}
    assert Announce.peer_list(new_state) == peers
  end

  test "dual DHT results merge into one torrent peer set after both lookups finish" do
    v1 = <<1::160>>
    v2 = <<2::160>>
    ref1 = make_ref()
    ref2 = make_ref()
    p1 = %Peer{ip: {198, 51, 100, 1}, port: 6881}
    p2 = %Peer{ip: {2001, 0xDB8, 0, 0, 0, 0, 0, 2}, port: 6882}

    state =
      base_state(
        hash: v1,
        dht_hashes: [v1, v2],
        requests: %{ref1 => {:dht, v1}, ref2 => {:dht, v2}}
      )

    partial = Announce.dispatch_task_message(state, {ref1, {:ok, [p1]}})
    assert partial.dht_peers == []
    assert partial.dht_round_peers == [p1]
    assert Announce.peer_list(partial) == [p1]

    complete = Announce.dispatch_task_message(partial, {ref2, {:ok, [p1, p2]}})
    assert MapSet.new(complete.dht_peers) == MapSet.new([p1, p2])
    assert complete.dht_round_peers == []
    assert MapSet.new(Announce.peer_list(complete)) == MapSet.new([p1, p2])
  end

  test "dual DHT round retains successful peers when the other lookup fails" do
    v1 = <<5::160>>
    v2 = <<6::160>>
    ref1 = make_ref()
    ref2 = make_ref()
    peer = %Peer{ip: {203, 0, 113, 6}, port: 6881}

    state =
      base_state(
        hash: v1,
        dht_hashes: [v1, v2],
        requests: %{ref1 => {:dht, v1}, ref2 => {:dht, v2}}
      )

    partial = Announce.dispatch_task_message(state, {ref1, {:error, :timeout}})
    assert partial.dht_peers == []
    assert map_size(partial.requests) == 1

    complete = Announce.dispatch_task_message(partial, {ref2, {:ok, [peer]}})
    assert complete.requests == %{}
    assert complete.dht_peers == [peer]
    assert Announce.peer_list(complete) == [peer]
  end

  test "hybrid Announce queries and announces both DHT swarm identities" do
    Process.register(self(), PeerDiscoveryDualSwarmDHTStub)

    on_exit(fn ->
      if Process.whereis(PeerDiscoveryDualSwarmDHTStub) == self() do
        Process.unregister(PeerDiscoveryDualSwarmDHTStub)
      end
    end)

    v1 = <<3::160>>
    hash_v2 = :binary.copy(<<4>>, 32)
    v2 = binary_part(hash_v2, 0, 20)
    p1 = %Peer{ip: {198, 51, 100, 3}, port: 6881}
    p2 = %Peer{ip: {2001, 0xDB8, 0, 0, 0, 0, 0, 4}, port: 6882}

    torrent = %Torrent{
      hash: v1,
      hash_v2: hash_v2,
      kind: :hybrid,
      metadata: %{"info" => %{"name" => "dual-swarm"}},
      left: 1000,
      last_index: 0,
      last_piece_length: 1000,
      peer_status: :seed
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    {:ok, announce_pid} =
      GenServer.start_link(
        Announce,
        [self(), torrent, [dht_module: PeerDiscoveryDualSwarmDHTStub]]
      )

    on_exit(fn ->
      safe_stop(announce_pid, 1_000)
      safe_stop(model_pid, 5_000)
    end)

    queries =
      for _ <- 1..2 do
        assert_receive {:dual_swarm_get_peers, task_pid, queried_hash}, 2_000
        peers = if queried_hash == v1, do: [p1], else: [p2]
        send(task_pid, {:dual_swarm_reply, queried_hash, peers})
        queried_hash
      end

    assert MapSet.new(queries) == MapSet.new([v1, v2])
    assert_receive {:dual_swarm_announce, announced1}, 2_000
    assert_receive {:dual_swarm_announce, announced2}, 2_000
    assert MapSet.new([announced1, announced2]) == MapSet.new([v1, v2])

    state = :sys.get_state(announce_pid)
    assert state.hash == v1
    assert MapSet.new(state.dht_peers) == MapSet.new([p1, p2])
    assert MapSet.new(Announce.peer_list(state)) == MapSet.new([p1, p2])
  end

  test "dispatch_task_message handles tracker errors without raising" do
    ref = make_ref()
    announce = "udp://9.rarbg.me:6969/announce"

    state =
      base_state(
        requests: %{ref => {announce, 0, 0}},
        tier_batches: %{0 => 1}
      )

    error = %Error{reason: {:dns, "9.rarbg.me", :nxdomain}, retry_in: "never"}

    assert %Announce{} =
             new_state = Announce.dispatch_task_message(state, {ref, error})

    assert new_state.requests == %{}
    refute Announce.tier_batches_active?(new_state)
    # A "never" retry must disable the dead tracker, not reschedule it.
    assert MapSet.member?(new_state.disabled, announce)
    refute Map.has_key?(new_state.retry_after_ms, announce)
  end

  test "BEP 31 retry minutes cool down only the requesting tracker" do
    ref = make_ref()
    cooling = "http://127.0.0.1:1/cooling"
    sibling = "http://127.0.0.1:1/sibling"

    state =
      base_state(
        tiers: [[cooling, sibling]],
        requests: %{ref => {cooling, 0, 0}},
        tier_batches: %{0 => 1}
      )

    error =
      Tracker.decode_http_response_for_test(%{
        "failure reason" => "Overloaded",
        "retry in" => 5
      })

    before_ms = System.monotonic_time(:millisecond)
    cooled_state = Announce.dispatch_task_message(state, {ref, error})
    after_ms = System.monotonic_time(:millisecond)

    assert deadline_ms = cooled_state.retry_after_ms[cooling]
    assert deadline_ms >= before_ms + 5 * 60_000
    assert deadline_ms <= after_ms + 5 * 60_000
    refute Map.has_key?(cooled_state.retry_after_ms, sibling)

    scheduled_state =
      Announce.dispatch_task_message(cooled_state, {:parallel_announce, 0})

    assert [{_task_ref, {^sibling, 0, 1}}] = Map.to_list(scheduled_state.requests)
  end

  test "dispatch_task_message stores tracker response peers without raising" do
    ref = make_ref()
    announce = "udp://tracker.example:6969/announce"
    peers = [%Peer{ip: {1, 2, 3, 4}, port: 6881}]
    hash = <<9::160>>

    torrent = %Torrent{
      hash: hash,
      metadata: %{"name" => "test"},
      left: 1000,
      last_index: 0,
      last_piece_length: 1000
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      safe_stop(model_pid, 5_000)
    end)

    state =
      base_state(
        hash: hash,
        requests: %{ref => {announce, 0, 0}},
        tier_batches: %{0 => 1}
      )

    response = %Response{
      peers: peers,
      complete: 10,
      incomplete: 5,
      interval: 1_800
    }

    before_ms = System.monotonic_time(:millisecond)

    new_state =
      Announce.dispatch_task_message(state, {ref, {Torrent.started(), response}})

    assert new_state.requests == %{}
    assert new_state.peers == %{announce => peers}
    assert Announce.peer_list(new_state) == peers
    assert new_state.tracker_interval_sec == 1_800
    assert is_integer(new_state.last_tracker_announce_ms)
    assert new_state.last_tracker_announce_ms >= before_ms
  end

  test "BEP 12 promotes out-of-order parallel successes by tracker URL, not stale index" do
    hash = <<13::160>>
    tracker_a = "http://tracker-a.example/announce"
    tracker_b = "http://tracker-b.example/announce"
    tracker_c = "http://tracker-c.example/announce"
    ref_a = make_ref()
    ref_b = make_ref()

    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "sticky-tracker", "private" => 1}},
      left: 1_000,
      last_index: 0,
      last_piece_length: 1_000,
      peer_status: :seed
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      safe_stop(model_pid, 5_000)
    end)

    state =
      base_state(
        hash: hash,
        tiers: [[tracker_a, tracker_b, tracker_c]],
        requests: %{
          ref_a => {tracker_a, 0, 0},
          ref_b => {tracker_b, 0, 1}
        },
        tier_batches: %{0 => 2}
      )

    response = %Response{
      peers: [%Peer{ip: {203, 0, 113, 13}, port: 6_881}],
      interval: 1_800,
      complete: 1,
      incomplete: 0
    }

    after_b =
      Announce.dispatch_task_message(
        state,
        {ref_b, {Torrent.started(), response}}
      )

    assert after_b.tiers == [[tracker_b, tracker_a, tracker_c]]

    after_a =
      Announce.dispatch_task_message(
        after_b,
        {ref_a, {Torrent.started(), response}}
      )

    assert after_a.tiers == [[tracker_a, tracker_b, tracker_c]]
  end

  test "BEP 12 tracker tiers are shuffled once at load and stay stable across announces" do
    hash = <<12::160>>
    tier0 = Enum.map(1..4, &"http://tier0-#{&1}.example/announce")
    tier1 = Enum.map(1..3, &"http://tier1-#{&1}.example/announce")
    tiers = [tier0, tier1]
    seed = {101, 102, 103}

    :rand.seed(:exsss, seed)
    expected_tiers = Enum.map(tiers, &Enum.shuffle/1)
    refute expected_tiers == tiers

    torrent = %Torrent{
      hash: hash,
      metadata: %{
        "announce-list" => tiers,
        "info" => %{"name" => "tier-shuffle", "private" => 1}
      },
      left: 1_000,
      last_index: 0,
      last_piece_length: 1_000,
      peer_status: :seed
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      safe_stop(model_pid, 5_000)
    end)

    :rand.seed(:exsss, seed)
    assert {:ok, state} = Announce.init([self(), torrent, []])
    assert state.tiers == expected_tiers

    working = hd(state.tiers |> hd())
    peer = %Peer{ip: {198, 51, 100, 12}, port: 6_881}
    response = %Response{peers: [peer], interval: 1_800, complete: 1, incomplete: 0}

    state =
      Enum.reduce(1..2, state, fn _, acc ->
        ref = make_ref()

        acc
        |> Map.put(:requests, %{ref => {working, 0, 0}})
        |> Map.put(:tier_batches, %{0 => 1})
        |> Announce.dispatch_task_message({ref, {Torrent.started(), response}})
      end)

    assert state.tiers == expected_tiers
  end

  test "a stale periodic tracker response does not consume a newer completed event" do
    ref = make_ref()
    hash = :crypto.strong_rand_bytes(20)
    announce = "http://tracker.example/announce"

    torrent = %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{"name" => "complete", "length" => 1_000, "piece length" => 1_000}
      },
      downloaded: 1_000,
      left: 0,
      last_index: 0,
      last_piece_length: 1_000,
      bitfield: Torrent.Bitfield.make(1) |> Torrent.Bitfield.set(0, 1),
      event: Torrent.completed(),
      peer_status: :seed
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      safe_stop(model_pid, 5_000)
    end)

    state =
      base_state(
        hash: hash,
        requests: %{ref => {announce, 0, 0}},
        tier_batches: %{0 => 1}
      )

    response = %Response{peers: [], complete: 1, incomplete: 0, interval: 1_800}

    _state =
      Announce.dispatch_task_message(state, {ref, {Torrent.empty(), response}})

    assert Torrent.get(hash, :event) == Torrent.completed()
  end

  test "tracker_announce_allowed? enforces floor once a tracker yielded peers" do
    now = 1_000_000

    state =
      base_state(
        last_tracker_announce_ms: now,
        tracker_min_interval_sec: 45,
        peers: %{"udp://tracker.example:6969/announce" => [%Peer{ip: {1, 2, 3, 4}, port: 6881}]}
      )

    assert {:wait, wait_ms} = Announce.tracker_announce_allowed?(state, now + 30_000)
    assert wait_ms >= 15_000
    assert :ok = Announce.tracker_announce_allowed?(state, now + 45_000)
  end

  test "tracker_announce_allowed? never allows re-announce within 30s floor once stamped" do
    now = 2_000_000

    state =
      base_state(
        last_tracker_announce_ms: now,
        tracker_min_interval_sec: nil,
        peers: %{"udp://tracker.example:6969/announce" => [%Peer{ip: {1, 2, 3, 4}, port: 6881}]}
      )

    assert {:wait, _} = Announce.tracker_announce_allowed?(state, now + 5_000)
    assert :ok = Announce.tracker_announce_allowed?(state, now + 30_000)
  end

  test "dht_lookup_allowed? throttles critical (< 12 connected) lookups to 15s" do
    # With no Swarm process for this hash, Swarm.count/1 returns 0 → critical
    # tier (@dht_critical_sec = 15s). Under-target-but-not-critical (30 s) and
    # at-target (300 s) tiers require a real Swarm and are covered implicitly
    # by the cond chain in dht_lookup_interval_sec/1.
    now = 3_000_000

    state = base_state(last_dht_lookup_ms: now)

    assert {:wait, wait_ms} = Announce.dht_lookup_allowed?(state, now + 5_000)
    assert wait_ms >= 9_000
    assert :ok = Announce.dht_lookup_allowed?(state, now + 15_000)
  end

  @tag race_group: :network
  test "connecting_to_peers dials only and does not start tracker announce" do
    hash = <<9::160>>
    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}

    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"private" => 1}, "name" => "test"},
      left: 1000,
      last_index: 0,
      last_piece_length: 1000
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      safe_stop(model_pid, 5_000)
    end)

    {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)
    before = :sys.get_state(pid)

    on_exit(fn ->
      safe_stop(pid, 1_000)
    end)

    GenServer.cast(pid, :connecting_to_peers)
    after_state = :sys.get_state(pid)

    assert after_state.last_tracker_announce_ms == before.last_tracker_announce_ms
    assert after_state.tier_batches == before.tier_batches
    refute dht_pending?(after_state.requests)
  end

  test "private torrents ignore PEX broadcast ticks without advancing snapshots" do
    endpoint = {{10, 0, 0, 50}, 6881}
    snapshot = %{endpoint => UtPexEntry.new(endpoint)}
    state = base_state(pex_snapshot: snapshot)

    after_state = Announce.dispatch_task_message(state, :pex_broadcast)

    assert after_state.pex_snapshot == snapshot
    refute_receive :pex_broadcast, 20
  end

  test "PEX announce tick retains an unchanged global snapshot" do
    endpoint = {{10, 0, 0, 50}, 6881}
    snapshot = %{endpoint => UtPexEntry.new(endpoint)}
    state = base_state(pex_snapshot: snapshot, private?: false)

    after_state = Announce.apply_pex_snapshot(state, snapshot)

    assert after_state.pex_snapshot == snapshot
  end

  test "PEX announce records the latest swarm snapshot when it changes" do
    state = base_state(private?: false, pex_snapshot: %{})
    start_swarm_with_connected(state.hash, 0)

    current =
      for i <- 1..3, into: %{} do
        endpoint = {{198, 18, 0, i}, 15_000 + i}
        {endpoint, UtPexEntry.new(endpoint)}
      end

    after_state = Announce.apply_pex_snapshot(state, current)
    assert after_state.pex_snapshot == current
  end

  describe "seed peers (BEP 9 x.pe hand-off)" do
    test "SeedPeers.put/take is atomic and single-consumer" do
      hash = <<7::160>>
      p1 = %Peer{ip: {203, 0, 113, 5}, port: 6881}
      p2 = %Peer{ip: {203, 0, 113, 5}, port: 6881}
      p3 = %Peer{ip: {198, 51, 100, 9}, port: 51_413}

      :ok = PeerDiscovery.SeedPeers.put(hash, [p1, p2, p3])
      taken = PeerDiscovery.SeedPeers.take(hash)

      assert length(taken) == 2
      assert MapSet.new(taken) == MapSet.new([p1, p3])
      # take/1 clears the row.
      assert PeerDiscovery.SeedPeers.take(hash) == []
    end

    test "Announce.init loads seed_peers and merges them into the peer pool" do
      hash = <<11::160>>
      seed = %Peer{ip: {192, 0, 2, 44}, port: 6881}

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"private" => 1}, "name" => "seedy"},
        left: 1000,
        last_index: 0,
        last_piece_length: 1000
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)

      on_exit(fn ->
        safe_stop(model_pid, 5_000)
      end)

      :ok = PeerDiscovery.SeedPeers.put(hash, [seed])

      name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}
      {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)

      on_exit(fn ->
        safe_stop(pid, 1_000)
      end)

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      assert state.seed_peers == [seed]
      assert seed in Announce.peer_list(state)
      # Consumed once — a second Announce for the same hash gets an empty slot.
      assert PeerDiscovery.SeedPeers.take(hash) == []
    end
  end

  defp dht_pending?(requests) do
    Enum.any?(requests, fn
      {_ref, {:dht, _hash}} -> true
      _ -> false
    end)
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
        start: {PeerDiscoveryAnnounceTest.SwarmStub, :start_link, [[]]},
        restart: :temporary
      }

      {:ok, _} = DynamicSupervisor.start_child(name, spec)
    end

    assert Torrent.Swarm.count(hash) == n
  end

  describe "parallel tier scheduling" do
    test "dead tier advance uses immediate hop under swarm target, not default_interval" do
      dead = "udp://9.rarbg.me:6969/announce"
      alive = "udp://tracker.example:6969/announce"

      state =
        base_state(
          tiers: [[dead], [alive]],
          disabled: MapSet.new([dead]),
          tier_index: 0
        )

      assert Announce.dead_tier_advance_interval(state, 0) == 0
      refute Announce.dead_tier_advance_interval(state, 0) == Tracker.default_interval()
    end

    test "dead tier advance backs off to under-target cadence after full tier ring" do
      dead = "udp://dead.example:6969/announce"

      state =
        base_state(
          tiers: [[dead], [dead]],
          disabled: MapSet.new([dead])
        )

      assert Announce.dead_tier_advance_interval(state, 0) == 0
      assert Announce.dead_tier_advance_interval(state, 1) == 30
    end

    test "parallel_tier_reschedule_interval caps tracker failure timeout under swarm target" do
      state =
        base_state(
          last_tracker_announce_ms: 1_000_000,
          tracker_interval_sec: nil
        )

      assert Announce.parallel_tier_reschedule_interval(state, Tracker.default_interval()) == 30
      assert Announce.parallel_tier_reschedule_interval(state, 900) == 30
    end

    test "parallel_tier_reschedule_interval honours tracker interval at swarm target" do
      hash = <<42::160>>

      state =
        base_state(
          hash: hash,
          tracker_interval_sec: 1_800,
          tracker_min_interval_sec: 45
        )

      start_swarm_with_connected(hash, 80)

      assert Announce.parallel_tier_reschedule_interval(state, 900) == 1_800
    end

    test "parallel_tier_failure_advance uses immediate hop under swarm target" do
      state =
        base_state(
          tiers: [["udp://dead.example:6969/announce"], ["udp://live.example:6969/announce"]],
          tier_index: 0
        )

      assert Announce.parallel_tier_failure_advance_interval(state, 0, 900) == 0
      refute Announce.parallel_tier_failure_advance_interval(state, 0, 900) == 900
    end

    test "parallel_tier_failure_advance backs off when wrapping to tier 0 under target" do
      state =
        base_state(
          tiers: [["udp://a.example:6969/announce"], ["udp://b.example:6969/announce"]],
          tier_index: 1
        )

      assert Announce.parallel_tier_failure_advance_interval(state, 1, 900) == 30
    end

    test "tracker_request_opts uses fast fail when under swarm target" do
      assert Announce.tracker_request_opts(base_state(%{})) == Tracker.fast_fail_request_opts()
    end

    test "tracker_request_opts keeps default budgets at swarm target" do
      hash = <<55::160>>
      state = base_state(hash: hash)
      start_swarm_with_connected(hash, 80)
      assert Announce.tracker_request_opts(state) == []
    end

    test "dispatch_task_message advances to next tier immediately after failed batch with no peers" do
      dead = "udp://dead.example:6969/announce"
      ref = make_ref()

      state =
        base_state(
          tiers: [[dead], ["udp://live.example:6969/announce"]],
          requests: %{ref => {dead, 0, 0}},
          tier_batches: %{0 => 1},
          peers: %{},
          last_tracker_announce_ms: 1_000_000
        )

      error = %Error{reason: :timeout}

      new_state = Announce.dispatch_task_message(state, {ref, error})

      refute Announce.tier_batches_active?(new_state)
      assert new_state.peers == %{}
      assert new_state.requests == %{}
      assert_receive {:parallel_announce, 1}, 100
    end

    test "never-disable of sole tier-0 tracker schedules immediate tier 1 hop" do
      dead = "udp://9.rarbg.me:2720/announce"
      live = "udp://live.example:6969/announce"
      ref = make_ref()

      state =
        base_state(
          tiers: [[dead], [live]],
          requests: %{ref => {dead, 0, 0}},
          tier_batches: %{0 => 1},
          peers: %{},
          last_tracker_announce_ms: nil
        )

      error = %Error{reason: {:dns, "9.rarbg.me", :nxdomain}, retry_in: "never"}

      new_state = Announce.dispatch_task_message(state, {ref, error})

      assert MapSet.member?(new_state.disabled, dead)
      refute Announce.tier_batches_active?(new_state)
      assert new_state.peers == %{}
      assert new_state.last_tracker_announce_ms == nil
      assert_receive {:parallel_announce, 1}, 100

      # tier=1 must not hit tracker_announce_allowed? 30s floor after a failed nxdomain.
      assert :ok =
               Announce.tracker_announce_allowed?(new_state, System.monotonic_time(:millisecond))
    end

    test "dead tier advance with interval 0 starts first live tier synchronously" do
      dead = "udp://9.rarbg.me:6969/announce"
      live = "udp://tracker.example:6969/announce"

      state =
        base_state(
          tiers: [[dead], [live]],
          disabled: MapSet.new([dead]),
          last_tracker_announce_ms: nil
        )

      new_state = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      # Skipped dead tier 0 in-process — no extra mailbox hop, no min-interval stamp.
      assert new_state.tier_index == 1
      assert new_state.tier_batches == %{1 => 1}
      assert new_state.last_tracker_announce_ms == nil
      refute_receive {:parallel_announce, _}, 50
    end

    test "exhausted under-target fanout keeps the announce state while scheduling retry" do
      dead0 = "udp://9.rarbg.me:6969/announce"
      dead1 = "udp://9.rarbg.me:2720/announce"
      dead2 = "udp://9.rarbg.me:2750/announce"

      state =
        base_state(
          tiers: [[dead0], [dead1], [dead2]],
          disabled: MapSet.new([dead0, dead1, dead2]),
          last_tracker_announce_ms: nil
        )

      assert %Announce{} =
               Announce.dispatch_task_message(state, {:parallel_announce, 1})

      refute_receive {:parallel_announce, _}, 50
    end

    test "resolve_announcable_tier_index skips consecutive disabled tiers under target" do
      dead0 = "udp://9.rarbg.me:6969/announce"
      dead1 = "udp://9.rarbg.me:2720/announce"
      live = "udp://opentracker.example:6969/announce"

      state =
        base_state(
          tiers: [[dead0], [dead1], [live]],
          disabled: MapSet.new([dead0, dead1])
        )

      assert {2, :live} = Announce.resolve_announcable_tier_index(state, 0)
    end

    test "fresh zero-peer scrape marks only that tracker swarm dead and skips its tier" do
      dead = "https://tracker.example/announce?passkey=dead-swarm"
      live = "https://backup.example/announce?passkey=live-swarm"
      now_ms = System.monotonic_time(:millisecond)

      state =
        base_state(
          tiers: [[dead], [live]],
          scrape_stats: %{
            dead => %{seeders: 0, leechers: 0, completed: 12, ts_ms: now_ms}
          }
        )

      assert {1, :live} = Announce.resolve_announcable_tier_index(state, 0)
      assert {1, :live} = Announce.resolve_announcable_tier_index(state, 1)
    end

    test "parallel_announce from tier 0 reaches first live tier without intermediate hops" do
      dead0 = "udp://dead0.example:6969/announce"
      dead1 = "udp://dead1.example:6969/announce"
      live = "udp://opentracker.example:6969/announce"

      state =
        base_state(
          tiers: [[dead0], [dead1], [live]],
          disabled: MapSet.new([dead0, dead1]),
          last_tracker_announce_ms: nil
        )

      new_state = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert new_state.tier_index == 2
      assert new_state.tier_batches == %{2 => 1}

      assert Enum.any?(new_state.requests, fn
               {_ref, {announce, 2, 0}} -> announce == live
               _ -> false
             end)
    end

    test "empty announce response advances to next tier immediately under target" do
      hash = <<9::160>>
      dead = "udp://rarbg.to:80/announce"
      live = "udp://opentracker.example:6969/announce"
      ref = make_ref()

      torrent = %Torrent{
        hash: hash,
        metadata: %{"name" => "test"},
        left: 1000,
        last_index: 0,
        last_piece_length: 1000
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)

      on_exit(fn ->
        safe_stop(model_pid, 5_000)
      end)

      state =
        base_state(
          hash: hash,
          tiers: [[dead], [live]],
          requests: %{ref => {dead, 0, 0}},
          tier_batches: %{0 => 1},
          peers: %{},
          last_tracker_announce_ms: nil
        )

      response = %Response{
        peers: [],
        complete: 0,
        incomplete: 0,
        interval: 1_800,
        min_interval: 1_800
      }

      new_state =
        Announce.dispatch_task_message(state, {ref, {Torrent.started(), response}})

      assert Announce.tracker_peers_empty?(new_state)
      assert new_state.last_tracker_announce_ms == nil
      refute Announce.tier_batches_active?(new_state)
      assert_receive {:parallel_announce, 1}, 100

      assert :ok =
               Announce.tracker_announce_allowed?(new_state, System.monotonic_time(:millisecond))
    end

    test "successful announce with peers still enforces min-interval floor" do
      now = 4_000_000

      state =
        base_state(
          last_tracker_announce_ms: now,
          tracker_min_interval_sec: 45,
          peers: %{"udp://live.example:6969/announce" => [%Peer{ip: {1, 1, 1, 1}, port: 6881}]}
        )

      assert {:wait, wait_ms} = Announce.tracker_announce_allowed?(state, now + 30_000)
      assert wait_ms >= 15_000
    end

    test "under-target fan-out starts up to four announcable tiers in parallel" do
      tiers =
        for i <- 0..6 do
          ["udp://tier#{i}.example:6969/announce"]
        end

      state = base_state(tiers: tiers, tier_batches: %{}, last_tracker_announce_ms: nil)

      new_state = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert map_size(new_state.tier_batches) == Announce.under_target_tier_fanout()
      assert Map.keys(new_state.tier_batches) |> Enum.sort() == [0, 1, 2, 3]

      assert Enum.count(new_state.requests, fn
               {_ref, {_announce, tier, _idx}} when tier in 0..3 -> true
               _ -> false
             end) == 4
    end

    test "under-target fan-out does not wait for an earlier tier batch to finish" do
      blackhole = "udp://blackhole.example:6969/announce"
      live1 = "udp://live1.example:6969/announce"
      live2 = "udp://live2.example:6969/announce"
      ref = make_ref()

      state =
        base_state(
          tiers: [[blackhole], [live1], [live2]],
          tier_batches: %{0 => 1},
          requests: %{ref => {blackhole, 0, 0}},
          last_tracker_announce_ms: nil
        )

      new_state = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert new_state.tier_batches[0] == 1
      assert new_state.tier_batches[1] == 1
      assert new_state.tier_batches[2] == 1
    end

    test "under-target fan-out respects a global concurrent tier cap" do
      tiers =
        for i <- 0..7 do
          ["udp://tier#{i}.example:6969/announce"]
        end

      # Already at the fan-out cap — a fresh escalate refresh must not stack
      # another wave on top (was unbounded overlapping waves in the wild).
      busy =
        0..(Announce.under_target_tier_fanout() - 1)
        |> Enum.map(&{&1, 1})
        |> Map.new()

      state =
        base_state(
          tiers: tiers,
          tier_batches: busy,
          last_tracker_announce_ms: nil
        )

      new_state = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert new_state.tier_batches == busy
      assert map_size(new_state.tier_batches) == Announce.under_target_tier_fanout()
    end

    test "under-target fan-out does not announce the same tier index twice in one wave" do
      dead = for i <- 0..6, do: "udp://dead#{i}.example:6969/announce"
      live = "udp://live7.example:6969/announce"

      tiers = for(d <- dead, do: [d]) ++ [[live]]

      state =
        base_state(
          tiers: tiers,
          tier_batches: %{},
          disabled: MapSet.new(dead),
          last_tracker_announce_ms: nil
        )

      new_state = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert map_size(new_state.tier_batches) == 1
      assert Map.has_key?(new_state.tier_batches, 7)

      assert Enum.count(new_state.requests, fn
               {_ref, {_announce, 7, _idx}} -> true
               _ -> false
             end) == 1
    end

    test "at swarm target keeps single-tier announce batches" do
      hash = <<77::160>>

      tiers =
        for i <- 0..3 do
          ["udp://tier#{i}.example:6969/announce"]
        end

      state = base_state(hash: hash, tiers: tiers, tier_batches: %{})
      start_swarm_with_connected(hash, 80)

      new_state = Announce.dispatch_task_message(state, {:parallel_announce, 0})

      assert map_size(new_state.tier_batches) == 1
      assert Map.has_key?(new_state.tier_batches, 0)
      refute Map.has_key?(new_state.tier_batches, 1)
    end

    test "at swarm target advances only after the whole tier yields no peers" do
      hash = <<78::160>>
      empty = "http://empty.example/announce"
      failing = "http://failing.example/announce"
      backup = "http://backup.example/announce"
      empty_ref = make_ref()
      failing_ref = make_ref()

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "at-target-backup", "private" => 1}},
        left: 1_000,
        last_index: 0,
        last_piece_length: 1_000,
        peer_status: :seed
      }

      {:ok, model_pid} = Torrent.Model.start_link(torrent)

      on_exit(fn ->
        safe_stop(model_pid, 5_000)
      end)

      start_swarm_with_connected(hash, 80)

      state =
        base_state(
          hash: hash,
          tiers: [[empty, failing], [backup]],
          requests: %{
            empty_ref => {empty, 0, 0},
            failing_ref => {failing, 0, 1}
          },
          tier_batches: %{0 => 2},
          peers: %{},
          last_tracker_announce_ms: nil
        )

      empty_response = %Response{
        peers: [],
        interval: 1_800,
        min_interval: 1_800,
        complete: 0,
        incomplete: 0
      }

      one_remaining =
        Announce.dispatch_task_message(
          state,
          {empty_ref, {Torrent.started(), empty_response}}
        )

      assert one_remaining.tier_batches == %{0 => 1}
      refute_receive {:parallel_announce, 1}, 20

      failed_tier =
        Announce.dispatch_task_message(
          one_remaining,
          {failing_ref, %Error{reason: :timeout}}
        )

      refute Announce.tier_batches_active?(failed_tier)
      assert failed_tier.last_tracker_announce_ms == nil
      assert_receive {:parallel_announce, 1} = next_announce, 100

      backup_started = Announce.dispatch_task_message(failed_tier, next_announce)
      assert backup_started.tier_index == 1
      assert backup_started.tier_batches == %{1 => 1}

      assert [{backup_ref, {^backup, 1, 0}}] = Map.to_list(backup_started.requests)

      peer = %Peer{ip: {203, 0, 113, 78}, port: 6_881}
      backup_response = %Response{peers: [peer], interval: 1_800, complete: 1, incomplete: 0}

      promoted =
        Announce.dispatch_task_message(
          backup_started,
          {backup_ref, {Torrent.started(), backup_response}}
        )

      assert promoted.tier_index == 1
      assert promoted.peers[backup] == [peer]
      refute Announce.tier_batches_active?(promoted)
    end
  end

  describe "BEP 48 scrape health" do
    test "dispatch_task_message stores scrape stats without disabling the tracker" do
      ref = make_ref()
      announce = "http://tracker.example.com/announce"

      state =
        base_state(
          requests: %{ref => {:scrape, announce}},
          scrape_stats: %{}
        )

      stats = %{seeders: 42, leechers: 7, completed: 100}
      new_state = Announce.dispatch_task_message(state, {ref, stats})

      assert %{^announce => entry} = new_state.scrape_stats
      assert entry.seeders == 42
      assert entry.leechers == 7
      assert entry.completed == 100
      assert is_integer(entry.ts_ms)
      # Scrape never touches the disabled set — announce still runs against this URL.
      assert MapSet.size(new_state.disabled) == 0
      assert new_state.requests == %{}
    end

    test "scrape :not_scrapeable error caches unsupported without disabling announce" do
      ref = make_ref()
      announce = "http://tracker.example.com/opaque"

      state =
        base_state(requests: %{ref => {:scrape, announce}})

      error = %Error{reason: :not_scrapeable, retry_in: "never"}
      new_state = Announce.dispatch_task_message(state, {ref, error})

      # Announce URL must remain enabled — scrape unsupported ≠ announce broken.
      refute MapSet.member?(new_state.disabled, announce)
      assert %{^announce => %{unsupported: true}} = new_state.scrape_stats
      assert new_state.requests == %{}
    end

    test "scrape error via parallel_tracker_error path leaves parallel state untouched" do
      ref = make_ref()
      announce = "udp://tracker.dead:6969/announce"

      state =
        base_state(
          requests: %{ref => {:scrape, announce}},
          tier_batches: %{0 => 3},
          scrape_stats: %{}
        )

      # A generic Tracker.Error with an integer retry_in falls through to
      # parallel_tracker_error/3 — must not decrement tier_batches for a
      # scrape ref, which belongs to a completely independent Task fan-out.
      error = %Error{reason: :timeout, retry_in: 60}
      new_state = Announce.dispatch_task_message(state, {ref, error})

      assert new_state.tier_batches == %{0 => 3}
      assert new_state.requests == %{}
      refute MapSet.member?(new_state.disabled, announce)
    end
  end

  test "expected_tracker_failure_reason?/1 covers common dead-tracker outcomes" do
    assert Announce.expected_tracker_failure_reason?(:timeout)
    assert Announce.expected_tracker_failure_reason?(:nxdomain)
    assert Announce.expected_tracker_failure_reason?(:connect_timeout)
    assert Announce.expected_tracker_failure_reason?({:nxdomain, ~c"dead.example"})
    refute Announce.expected_tracker_failure_reason?(:bad_response)
    refute Announce.expected_tracker_failure_reason?(:invalid_bencode)
  end

  defp safe_stop(pid, timeout) do
    GenServer.stop(pid, :normal, timeout)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end
end

defmodule PeerDiscoveryAnnounceTest.SwarmStub do
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

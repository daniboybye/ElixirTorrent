defmodule NAT.NATPMPTest do
  use ExUnit.Case, async: true

  test "encode_map_request builds NAT-PMP map packet" do
    packet = NAT.NATPMP.encode_map_request(:tcp, 6881, 6881, 7200)

    assert <<0, 2, 0, 0, 6881::16, 6881::16, 7200::32>> = packet
  end

  test "decode_map_response accepts successful map reply" do
    reply = <<0, 2, 0, 0, 6881::16, 6881::16, 7200::32>>

    assert {:ok, 6881, 6881, 7200} = NAT.NATPMP.decode_map_response(reply)
  end
end

defmodule Peer.DialBackoffFilterTest do
  use ExUnit.Case, async: false

  @moduletag race_group: :dial

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "filter removes blocked endpoints" do
    hash = :crypto.strong_rand_bytes(20)
    peer = %Peer{ip: {1, 2, 3, 4}, port: 6881}

    :ok = Peer.DialBackoff.record(hash, peer.ip, peer.port, :timeout)
    _ = :sys.get_state(Peer.DialBackoff)

    assert Peer.DialBackoff.filter([peer], hash) == []
    assert Peer.DialBackoff.blocked?(hash, peer.ip, peer.port)
  end

  test "keeps allowed peers before blocked retries and prefers same-family blocked" do
    hash = :crypto.strong_rand_bytes(20)
    ipv6 = {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 0x0042}
    fresh_v6 = %Peer{ip: ipv6, port: 9001}
    blocked_v4 = %Peer{ip: {8, 8, 8, 8}, port: 6881}

    :ok = Peer.DialBackoff.record(hash, blocked_v4.ip, blocked_v4.port, :timeout)
    _ = :sys.get_state(Peer.DialBackoff)

    result = Peer.DialBackoff.filter([fresh_v6, blocked_v4], hash, 2)

    assert hd(result) == fresh_v6
    assert length(result) == 2
    assert Enum.at(result, 1) == blocked_v4
  end
end

defmodule Peer.ConnectionManagerTest do
  use ExUnit.Case, async: false

  alias Peer.ConnectionManager.Queue, as: DialQueue
  alias PeerDiscovery.Announce

  defp start_isolated_manager(hash) do
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}
    {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)
    :sys.replace_state(pid, &%{&1 | dialing?: true})
    pid
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "prioritize_dial_queue puts productive then BEP 11 seed-flagged peers first" do
    hash = :binary.copy(<<0xCD>>, 20)
    leech_a = %Peer{ip: {1, 1, 1, 1}, port: 6881}
    seed = %Peer{ip: {2, 2, 2, 2}, port: 6882, seed: true}
    leech_b = %Peer{ip: {3, 3, 3, 3}, port: 6883}
    productive = %Peer{ip: {4, 4, 4, 4}, port: 6884}

    if :ets.info(:peer_dial_productive) != :undefined,
      do: :ets.delete_all_objects(:peer_dial_productive)

    Peer.DialBackoff.mark_productive(hash, productive.ip, productive.port)
    _ = :sys.get_state(Peer.DialBackoff)

    assert Peer.ConnectionManager.prioritize_dial_queue(hash, [leech_a, seed, leech_b, productive]) ==
             [productive, seed, leech_a, leech_b]
  end

  test "offer_peers upgrades seed hint when a later batch marks the endpoint as seeder" do
    hash = :crypto.strong_rand_bytes(20)
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}
    {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(pid, 1_000)
    end)

    endpoint = {10, 0, 0, 1}
    port = 9001

    :ok =
      Peer.ConnectionManager.offer_peers(hash, [
        %Peer{ip: endpoint, port: port}
      ])

    :ok =
      Peer.ConnectionManager.offer_peers(hash, [
        %Peer{ip: endpoint, port: port, seed: true}
      ])

    state = :sys.get_state(pid)
    assert DialQueue.get_peer(state.queue, {endpoint, port}).seed == true
  end

  test "offer_peers enqueues unique endpoints" do
    hash = :crypto.strong_rand_bytes(20)
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}
    {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(pid, 1_000)
    end)

    peers = [
      %Peer{ip: {1, 1, 1, 1}, port: 6881},
      %Peer{ip: {1, 1, 1, 1}, port: 6881},
      %Peer{ip: {2, 2, 2, 2}, port: 6882}
    ]

    :ok = Peer.ConnectionManager.offer_peers(hash, peers)

    state = :sys.get_state(pid)
    assert map_size(state.queue) == 2
  end

  @tag race_group: :dial
  test "stopping the manager terminates its active dial batch" do
    hash = :crypto.strong_rand_bytes(20)
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}
    {:ok, manager_pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)

    {dial_pid, _dial_mon, _dial_release} = TestSupport.Sync.spawn_blocked()

    on_exit(fn ->
      TestSupport.Sync.safe_stop(manager_pid, 1_000)
      Process.exit(dial_pid, :kill)
    end)

    :sys.replace_state(manager_pid, &%{&1 | dialing?: true, dial_task: dial_pid})

    ref = Process.monitor(dial_pid)
    assert :ok = GenServer.stop(manager_pid, :normal, 1_000)
    assert_receive {:DOWN, ^ref, :process, ^dial_pid, :shutdown}, 1_000
  end

  describe "source-aware candidate retention (PEX item 5)" do
    alias Peer.ConnectionManager.Queue, as: DialQueue

    defp pub4(n), do: {11, 0, 0, rem(n, 250)}

    test "discovery ownership survives a remote PEX drop" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_isolated_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      ep = %Peer{ip: pub4(1), port: 9001}
      supplier = <<1::160>>

      :ok = Peer.ConnectionManager.offer_peers(hash, [ep])
      :ok = Peer.ConnectionManager.offer_peers_from_pex(hash, supplier, [ep])
      :ok = Peer.ConnectionManager.revoke_pex_peers(hash, supplier, [ep])

      state = :sys.get_state(pid)
      assert DialQueue.get_peer(state.queue, {ep.ip, ep.port}) == ep
    end

    test "two PEX suppliers — drop from one leaves the other's tag" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_isolated_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      ep = %Peer{ip: pub4(2), port: 9002}
      a = <<2::160>>
      b = <<3::160>>

      :ok = Peer.ConnectionManager.offer_peers_from_pex(hash, a, [ep])
      :ok = Peer.ConnectionManager.offer_peers_from_pex(hash, b, [ep])
      :ok = Peer.ConnectionManager.revoke_pex_peers(hash, a, [ep])

      state = :sys.get_state(pid)
      entry = Map.fetch!(state.queue, {ep.ip, ep.port})
      assert MapSet.member?(entry.sources, {:pex, b})
      refute MapSet.member?(entry.sources, {:pex, a})
    end

    test "drop from a different PEX supplier cannot revoke the owner" do
      ep = %Peer{ip: pub4(22), port: 9022}
      owner = <<22::160>>
      stranger = <<23::160>>

      queue =
        %{}
        |> DialQueue.offer([ep], {:pex, owner})
        |> DialQueue.revoke_pex(stranger, [ep])

      entry = Map.fetch!(queue, {ep.ip, ep.port})
      assert entry.sources == MapSet.new([{:pex, owner}])
    end

    test "sole PEX source drop removes endpoint from queue" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_isolated_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      ep = %Peer{ip: pub4(3), port: 9003}
      supplier = <<4::160>>

      :ok = Peer.ConnectionManager.offer_peers_from_pex(hash, supplier, [ep])
      :ok = Peer.ConnectionManager.revoke_pex_peers(hash, supplier, [ep])

      state = :sys.get_state(pid)
      assert map_size(state.queue) == 0
    end

    test "pure queue merges seed hints across sources" do
      ep = pub4(4)
      port = 9004

      q =
        %{}
        |> DialQueue.offer([%Peer{ip: ep, port: port}], :discovery)
        |> DialQueue.offer([%Peer{ip: ep, port: port, seed: true}], {:pex, <<5::160>>})

      assert DialQueue.get_peer(q, {ep, port}).seed == true
    end
  end

  describe "throughput-aware discovery escalation" do
    @full_queue 45
    @low_speed_bytes_per_sec 32_768

    defp swarm_via(hash), do: {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

    defp manager_via(hash), do: {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}

    defp announce_via(hash), do: Announce.name(hash)

    defp start_swarm_with_connected(hash, n) when n >= 0 do
      name = swarm_via(hash)

      case DynamicSupervisor.start_link(name: name, strategy: :one_for_one) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      current = Torrent.Swarm.count(hash)

      for _ <- 1..max(n - current, 0) do
        spec = %{
          id: :dummy_peer,
          start: {Peer.ConnectionManagerTest.SwarmStub, :start_link, [[]]},
          restart: :temporary
        }

        {:ok, _} = DynamicSupervisor.start_child(name, spec)
      end

      assert Torrent.Swarm.count(hash) == n
    end

    defp start_model(hash, download_speed) do
      torrent = %Torrent{
        hash: hash,
        metadata: %{"name" => "escalate-test"},
        left: 1_000_000,
        last_index: 0,
        last_piece_length: 1000,
        speed: if(download_speed, do: %{download: download_speed, upload: 0})
      }

      {:ok, pid} = Torrent.Model.start_link(torrent)
      pid
    end

    defp start_announce_spy(hash) do
      {:ok, pid} = GenServer.start_link(__MODULE__.AnnounceSpy, nil, name: announce_via(hash))
      pid
    end

    defp start_manager(hash) do
      {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: manager_via(hash))
      pid
    end

    defp fill_queue(manager_pid, n) do
      queue =
        for i <- 1..n, reduce: %{} do
          acc ->
            peer = %Peer{ip: {10, 0, rem(i, 250), rem(i, 250)}, port: 6000 + i}
            DialQueue.offer(acc, [peer], :discovery)
        end

      :sys.replace_state(manager_pid, fn state ->
        %{state | queue: queue, dialing?: false}
      end)
    end

    defp discovery_counts(announce_pid) do
      GenServer.call(announce_pid, :discovery_counts)
    end

    defp tick(manager_pid) do
      send(manager_pid, :tick)
      _ = :sys.get_state(manager_pid)
    end

    defp safe_stop(pid) when is_pid(pid) do
      TestSupport.Sync.safe_stop(pid, 1_000)
    end

    defp setup_escalation_scenario(connected, opts \\ []) do
      hash = Keyword.get(opts, :hash, :crypto.strong_rand_bytes(20))
      download_speed = Keyword.get(opts, :download_speed)

      start_swarm_with_connected(hash, connected)

      model_pid =
        if download_speed != :none do
          start_model(hash, download_speed)
        end

      announce_pid = start_announce_spy(hash)
      manager_pid = start_manager(hash)
      fill_queue(manager_pid, @full_queue)

      on_exit(fn ->
        for pid <- [manager_pid, announce_pid, model_pid] do
          safe_stop(pid)
        end

        case GenServer.whereis(swarm_via(hash)) do
          nil -> :ok
          swarm_pid -> safe_stop(swarm_pid)
        end
      end)

      {hash, manager_pid, announce_pid}
    end

    test "escalates discovery when connected is above soft 25 but below target with dead throughput" do
      {_hash, manager_pid, announce_pid} = setup_escalation_scenario(31)

      tick(manager_pid)

      assert discovery_counts(announce_pid) == {1, 1}
    end

    test "escalates at connected=25 with low throughput (old soft threshold excluded this)" do
      {_hash, manager_pid, announce_pid} = setup_escalation_scenario(25)

      tick(manager_pid)

      assert discovery_counts(announce_pid) == {1, 1}
    end

    test "does not escalate when download speed clears the low threshold" do
      {_hash, manager_pid, announce_pid} =
        setup_escalation_scenario(31, download_speed: @low_speed_bytes_per_sec)

      tick(manager_pid)

      assert discovery_counts(announce_pid) == {0, 0}
    end

    test "does not escalate once connected reaches target even with dead throughput" do
      {_hash, manager_pid, announce_pid} = setup_escalation_scenario(50)

      tick(manager_pid)

      assert discovery_counts(announce_pid) == {0, 0}
    end

    test "still escalates below low_connected_threshold regardless of healthy throughput" do
      {_hash, manager_pid, announce_pid} =
        setup_escalation_scenario(8, download_speed: @low_speed_bytes_per_sec)

      tick(manager_pid)

      assert discovery_counts(announce_pid) == {1, 1}
    end
  end

  describe "cap eviction when throughput is dead" do
    @swarm_cap 60
    @low_speed_bytes_per_sec 32_768

    defp start_swarm_only(hash) do
      name = swarm_via(hash)

      case DynamicSupervisor.start_link(name: name, strategy: :one_for_one) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    defp start_download_model(hash, download_speed) do
      torrent = %Torrent{
        hash: hash,
        metadata: %{"name" => "evict-test"},
        left: 1_000_000,
        last_index: 3,
        last_piece_length: 16_384,
        peer_status: nil,
        speed: if(download_speed, do: %{download: download_speed, upload: 0})
      }

      {:ok, pid} = Torrent.Model.start_link(torrent)
      pid
    end

    defp add_mock_peers(hash, configs) do
      swarm = swarm_via(hash)

      Enum.each(configs, fn opts ->
        id = Keyword.fetch!(opts, :id)

        spec = %{
          id: {:mock_peer, id},
          start: {__MODULE__.MockPeer, :start_link, [hash, id, opts]},
          restart: :temporary
        }

        {:ok, _} = DynamicSupervisor.start_child(swarm, spec)
      end)
    end

    defp fill_swarm_to_cap(hash, extra_configs) do
      base =
        for i <- 1..(@swarm_cap - length(extra_configs)) do
          [
            id: <<i::160>>,
            age_ms: 120_000,
            downloaded_bytes: 32_768,
            bitfield: :all,
            choke_me: false
          ]
        end

      add_mock_peers(hash, base ++ extra_configs)
      assert Torrent.Swarm.count(hash) == @swarm_cap
    end

    defp setup_eviction_scenario(extra_peer_configs, opts \\ []) do
      hash = Keyword.get(opts, :hash, :crypto.strong_rand_bytes(20))
      download_speed = Keyword.get(opts, :download_speed)

      start_swarm_only(hash)
      model_pid = start_download_model(hash, download_speed)
      fill_swarm_to_cap(hash, extra_peer_configs)
      manager_pid = start_manager(hash)

      on_exit(fn ->
        safe_stop(manager_pid)
        safe_stop(model_pid)

        case GenServer.whereis(swarm_via(hash)) do
          nil -> :ok
          swarm_pid -> safe_stop(swarm_pid)
        end
      end)

      {hash, manager_pid}
    end

    test "evicts zero-upload peer past grace when at cap with dead throughput" do
      stale_id = <<99::160>>

      {hash, manager_pid} =
        setup_eviction_scenario([
          [
            id: stale_id,
            age_ms: 90_000,
            downloaded_bytes: 0,
            bitfield: :none,
            choke_me: true
          ]
        ])

      assert Torrent.Swarm.count(hash) == @swarm_cap

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == @swarm_cap - 1
      refute Peer.whereis(hash, stale_id)
    end

    test "does not evict fresh zero-upload peer before grace" do
      fresh_id = <<88::160>>

      {hash, manager_pid} =
        setup_eviction_scenario([
          [
            id: fresh_id,
            age_ms: 10_000,
            downloaded_bytes: 0,
            bitfield: :none,
            choke_me: true
          ]
        ])

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == @swarm_cap
      assert Peer.whereis(hash, fresh_id)
    end

    test "does not evict when download speed is healthy" do
      stale_id = <<77::160>>

      {hash, manager_pid} =
        setup_eviction_scenario(
          [
            [
              id: stale_id,
              age_ms: 90_000,
              downloaded_bytes: 0,
              bitfield: :none,
              choke_me: true
            ]
          ],
          download_speed: @low_speed_bytes_per_sec
        )

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == @swarm_cap
      assert Peer.whereis(hash, stale_id)
    end
  end

  describe "snub eviction below swarm cap" do
    @snub_evict_batch 2
    @snub_grace_ms 60_000
    @idle_unchoked_snub_ms 30_000
    @low_speed_bytes_per_sec 32_768

    defp productive_peer(id) do
      [
        id: id,
        age_ms: 130_000,
        downloaded_bytes: 32_768,
        bitfield: :all,
        choke_me: false
      ]
    end

    defp stale_zero_byte_peer(id, age_ms \\ @snub_grace_ms + 10_000, opts \\ []) do
      idle_ms = Keyword.get(opts, :idle_ms, age_ms)

      [
        id: id,
        age_ms: age_ms,
        idle_ms: idle_ms,
        downloaded_bytes: 0,
        bitfield: Keyword.get(opts, :bitfield, :none),
        choke_me: Keyword.get(opts, :choke_me, true)
      ]
    end

    defp setup_snub_scenario(connected_count, extra_configs, opts \\ []) do
      hash = Keyword.get(opts, :hash, :crypto.strong_rand_bytes(20))
      download_speed = Keyword.get(opts, :download_speed)

      start_swarm_only(hash)
      model_pid = start_download_model(hash, download_speed)

      filler_count = connected_count - length(extra_configs)

      base =
        for i <- 1..filler_count do
          productive_peer(<<i::160>>)
        end

      add_mock_peers(hash, base ++ extra_configs)
      assert Torrent.Swarm.count(hash) == connected_count
      manager_pid = start_manager(hash)

      on_exit(fn ->
        safe_stop(manager_pid)
        safe_stop(model_pid)

        case GenServer.whereis(swarm_via(hash)) do
          nil -> :ok
          swarm_pid -> safe_stop(swarm_pid)
        end
      end)

      {hash, manager_pid}
    end

    test "snubs up to batch size when low speed with old zero-byte peers" do
      stale_ids = [<<101::160>>, <<102::160>>, <<103::160>>]

      {hash, manager_pid} =
        setup_snub_scenario(20, Enum.map(stale_ids, &stale_zero_byte_peer/1))

      assert Torrent.Swarm.count(hash) == 20

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20 - @snub_evict_batch

      evicted =
        Enum.count(stale_ids, fn id ->
          Peer.whereis(hash, id) == nil
        end)

      assert evicted == @snub_evict_batch
    end

    test "does not snub when download speed is healthy" do
      stale_id = <<201::160>>

      {hash, manager_pid} =
        setup_snub_scenario(
          20,
          [stale_zero_byte_peer(stale_id)],
          download_speed: @low_speed_bytes_per_sec
        )

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20
      assert Peer.whereis(hash, stale_id)
    end

    test "does not snub fresh zero-byte peers before grace" do
      fresh_ids = [<<301::160>>, <<302::160>>, <<303::160>>]

      {hash, manager_pid} =
        setup_snub_scenario(
          20,
          Enum.map(fresh_ids, fn id -> stale_zero_byte_peer(id, @snub_grace_ms - 10_000) end)
        )

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20

      for id <- fresh_ids do
        assert Peer.whereis(hash, id)
      end
    end

    test "snubs choke-cycling zero-byte peers (unchoked at tick but age past grace)" do
      cycler_ids = [<<401::160>>, <<402::160>>, <<403::160>>]

      {hash, manager_pid} =
        setup_snub_scenario(
          20,
          Enum.map(cycler_ids, fn id ->
            stale_zero_byte_peer(id, @snub_grace_ms + 5_000, choke_me: false)
          end)
        )

      assert Torrent.Swarm.count(hash) == 20

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20 - @snub_evict_batch

      evicted =
        Enum.count(cycler_ids, fn id ->
          Peer.whereis(hash, id) == nil
        end)

      assert evicted == @snub_evict_batch
    end

    test "snubs unchoked zero-byte peer idle past idle_unchoked threshold before wall-clock grace" do
      idle_id = <<501::160>>
      age_ms = @idle_unchoked_snub_ms + 5_000
      idle_ms = @idle_unchoked_snub_ms + 5_000

      {hash, manager_pid} =
        setup_snub_scenario(
          20,
          [
            stale_zero_byte_peer(idle_id, age_ms,
              idle_ms: idle_ms,
              choke_me: false
            )
          ]
        )

      assert Torrent.Swarm.count(hash) == 20

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 19
      refute Peer.whereis(hash, idle_id)
    end

    test "does not snub unchoked peer that recently received a block" do
      active_id = <<601::160>>
      age_ms = @idle_unchoked_snub_ms + 10_000

      {hash, manager_pid} =
        setup_snub_scenario(
          20,
          [
            stale_zero_byte_peer(active_id, age_ms,
              idle_ms: 1_000,
              choke_me: false
            )
          ]
        )

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20
      assert Peer.whereis(hash, active_id)
    end

    test "does not snub useful seeder with zero downloaded bytes" do
      seeder_id = <<701::160>>

      {hash, manager_pid} =
        setup_snub_scenario(
          20,
          [
            stale_zero_byte_peer(seeder_id, @snub_grace_ms + 10_000,
              bitfield: :all,
              choke_me: false
            )
          ]
        )

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20
      assert Peer.whereis(hash, seeder_id)
    end

    test "skips second snub batch within cooldown interval" do
      stale_ids = [<<801::160>>, <<802::160>>, <<803::160>>, <<804::160>>]

      {hash, manager_pid} =
        setup_snub_scenario(20, Enum.map(stale_ids, &stale_zero_byte_peer/1))

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20 - @snub_evict_batch

      evicted_after_first =
        Enum.count(stale_ids, fn id -> Peer.whereis(hash, id) == nil end)

      assert evicted_after_first == @snub_evict_batch

      tick(manager_pid)

      assert Torrent.Swarm.count(hash) == 20 - @snub_evict_batch

      evicted_after_second =
        Enum.count(stale_ids, fn id -> Peer.whereis(hash, id) == nil end)

      assert evicted_after_second == @snub_evict_batch
    end
  end
end

defmodule Peer.ConnectionManagerTest.SwarmStub do
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

defmodule Peer.ConnectionManagerTest.MockPeer do
  @moduledoc false
  use GenServer

  def start_link(hash, id, opts) do
    GenServer.start_link(__MODULE__, {hash, id, opts})
  end

  def init({hash, id, opts}) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    {:ok, ctrl} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    Process.monitor(ctrl)

    now = System.monotonic_time(:millisecond)
    age_ms = Keyword.get(opts, :age_ms, 0)
    downloaded_bytes = Keyword.get(opts, :downloaded_bytes, 0)

    idle_ms =
      Keyword.get_lazy(opts, :idle_ms, fn ->
        if downloaded_bytes > 0, do: 1_000, else: age_ms
      end)

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{
        state
        | connected_at: now - age_ms,
          last_block_at: now - idle_ms,
          downloaded_bytes: downloaded_bytes,
          bitfield: Keyword.get(opts, :bitfield, :none),
          choke_me: Keyword.get(opts, :choke_me, true),
          interested: Keyword.get(opts, :interested, false)
      }
    end)

    {:ok, %{controller: ctrl}}
  end

  def handle_info({:DOWN, _, :process, _ctrl, _}, state), do: {:stop, :normal, state}
end

defmodule Peer.ConnectionManagerTest.AnnounceSpy do
  @moduledoc false
  use GenServer

  def init(nil), do: {:ok, %{refreshes: 0, replenishes: 0}}

  def handle_cast(:maybe_refresh_peers, state),
    do: {:noreply, %{state | refreshes: state.refreshes + 1}}

  def handle_cast(:replenish_candidates, state),
    do: {:noreply, %{state | replenishes: state.replenishes + 1}}

  def handle_call(:discovery_counts, _from, state),
    do: {:reply, {state.refreshes, state.replenishes}, state}
end

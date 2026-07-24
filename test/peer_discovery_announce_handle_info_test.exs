defmodule PeerDiscoveryAnnounceHandleInfoTest do
  use ExUnit.Case, async: false

  alias PeerDiscovery.Announce
  alias Tracker.{Error, Response}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  defp start_announce!(hash \\ <<50::160>>, tiers \\ [["http://tracker.example/announce"]]) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"name" => "lifecycle", "announce-list" => tiers},
      left: 1000,
      last_index: 0,
      last_piece_length: 1000
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      if Process.alive?(model_pid), do: GenServer.stop(model_pid, :normal, 5_000)
    end)

    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}
    {:ok, pid} = GenServer.start_link(Announce, [self(), torrent], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    {pid, hash}
  end

  test "handle_info tracker Response merges peers into state" do
    {pid, _hash} = start_announce!()
    ref = make_ref()
    announce = "http://tracker.example/announce"
    peer = %Peer{ip: {9, 9, 9, 9}, port: 6881}

    :sys.replace_state(pid, fn state ->
      %{state | requests: %{ref => {announce, 0, 0}}, tier_batches: %{0 => 1}}
    end)

    send(
      pid,
      {ref,
       {Torrent.started(), %Response{peers: [peer], interval: 600, complete: 1, incomplete: 2}}}
    )

    Process.sleep(30)

    state = :sys.get_state(pid)
    assert state.peers[announce] == [peer]
    refute Map.has_key?(state.requests, ref)
  end

  test "handle_info DHT get_peers success stores dht_peers" do
    {pid, _hash} = start_announce!()
    ref = make_ref()
    peers = [%Peer{ip: {8, 8, 8, 8}, port: 6881}]

    :sys.replace_state(pid, fn state ->
      %{state | requests: %{ref => {:dht, state.hash}}, dht_peers: []}
    end)

    send(pid, {ref, {:ok, peers}})
    Process.sleep(30)

    state = :sys.get_state(pid)
    assert state.dht_peers == peers
  end

  test "handle_info scrape stats stores BEP 48 health without disabling tracker" do
    {pid, _hash} = start_announce!()
    ref = make_ref()
    announce = "http://tracker.example/announce"

    :sys.replace_state(pid, fn state ->
      %{state | requests: %{ref => {:scrape, announce}}}
    end)

    send(pid, {ref, %{seeders: 1, leechers: 2, completed: 3}})
    Process.sleep(30)

    state = :sys.get_state(pid)
    assert %{^announce => entry} = state.scrape_stats
    assert entry.seeders == 1
    refute MapSet.member?(state.disabled, announce)
  end

  test "handle_info Overloaded error with string retry_in reschedules tracker" do
    {pid, _hash} = start_announce!()
    ref = make_ref()
    announce = "http://tracker.example/announce"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1},
          last_tracker_announce_ms: nil
      }
    end)

    send(pid, {ref, %Error{reason: "Overloaded", retry_in: "120"}})
    Process.sleep(30)

    state = :sys.get_state(pid)
    assert state.requests == %{}
    assert is_integer(state.tracker_interval_sec) or state.tracker_interval_sec == nil
  end

  test "handle_info generic tracker Error with never retry disables tracker" do
    {pid, _hash} = start_announce!()
    ref = make_ref()
    announce = "udp://dead.example:6969/announce"

    :sys.replace_state(pid, fn state ->
      %{
        state
        | requests: %{ref => {announce, 0, 0}},
          tier_batches: %{0 => 1}
      }
    end)

    send(pid, {ref, %Error{reason: {:dns, "dead.example", :nxdomain}, retry_in: "never"}})
    Process.sleep(30)

    state = :sys.get_state(pid)
    assert MapSet.member?(state.disabled, announce)
  end

  test "handle_cast maybe_refresh_peers and replenish_candidates keep process alive" do
    {pid, hash} = start_announce!()

    GenServer.cast(pid, :maybe_refresh_peers)
    GenServer.cast(pid, :replenish_candidates)
    :ok = PeerDiscovery.replenish_candidates(hash)
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "pop_request/2 removes ref from requests map" do
    ref = make_ref()

    state = %Announce{
      torrent_pid: self(),
      hash: <<0::160>>,
      requests: %{ref => {:dht, <<0::160>>}}
    }

    {meta, new_state} = Announce.pop_request(state, ref)
    assert meta == {:dht, <<0::160>>}
    assert new_state.requests == %{}
  end
end

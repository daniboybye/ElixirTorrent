defmodule MagnetPeerHandoffTest do
  # When a magnet's metadata arrives, the peers of the metadata phase must carry
  # over into the download instead of being dropped, and our own teardown of the
  # metadata swarm must not be counted against them as churn.
  use ExUnit.Case, async: false

  alias Magnet.Fetcher
  alias PeerDiscovery.SeedPeers
  alias TestSupport.Sync

  @timeout 2_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    previous_handler = Application.get_env(:elixir_torrent, :metadata_ok_handler)
    Application.put_env(:elixir_torrent, :metadata_ok_handler, nil)

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :metadata_ok_handler, previous_handler)
    end)

    hash = :crypto.strong_rand_bytes(20)
    on_exit(fn -> SeedPeers.take(hash) end)
    {:ok, hash: hash}
  end

  defp register_blocked(hash, ip, port) do
    {pid, monitor, release} = Sync.spawn_blocked()
    :ok = Peer.Endpoints.register(hash, ip, port, pid)
    {pid, monitor, release}
  end

  defp drop(pid, monitor) do
    Process.exit(pid, :kill)
    Sync.await_down(monitor, pid, @timeout)
    Sync.sync(Peer.Endpoints)
    Sync.sync(Peer.DialBackoff)
  end

  describe "Peer.Endpoints.release_for_handoff/1" do
    test "a quick disconnect is churn, unless the endpoint was handed off", %{hash: hash} do
      {churned, churned_ref, _} = register_blocked(hash, {10, 0, 0, 1}, 6881)
      drop(churned, churned_ref)
      assert Peer.DialBackoff.blocked?(hash, {10, 0, 0, 1}, 6881)

      {kept, kept_ref, _} = register_blocked(hash, {10, 0, 0, 2}, 6881)
      assert Peer.Endpoints.release_for_handoff(hash) == [{{10, 0, 0, 2}, 6881}]
      drop(kept, kept_ref)
      refute Peer.DialBackoff.blocked?(hash, {10, 0, 0, 2}, 6881)
    end

    test "the mark covers one connection, not the endpoint forever", %{hash: hash} do
      {first, first_ref, _} = register_blocked(hash, {10, 0, 0, 3}, 6881)
      [_] = Peer.Endpoints.release_for_handoff(hash)
      drop(first, first_ref)

      {second, second_ref, _} = register_blocked(hash, {10, 0, 0, 3}, 6881)
      drop(second, second_ref)
      assert Peer.DialBackoff.blocked?(hash, {10, 0, 0, 3}, 6881)
    end

    test "only the given torrent's endpoints are handed off", %{hash: hash} do
      other = :crypto.strong_rand_bytes(20)
      {mine, mine_ref, _} = register_blocked(hash, {10, 0, 0, 4}, 6881)
      {theirs, theirs_ref, _} = register_blocked(other, {10, 0, 0, 5}, 6881)

      assert Peer.Endpoints.release_for_handoff(hash) == [{{10, 0, 0, 4}, 6881}]

      drop(mine, mine_ref)
      drop(theirs, theirs_ref)
      refute Peer.DialBackoff.blocked?(hash, {10, 0, 0, 4}, 6881)
      assert Peer.DialBackoff.blocked?(other, {10, 0, 0, 5}, 6881)
    end
  end

  describe "Fetcher.handoff_peers/3" do
    setup %{hash: hash} do
      magnet = %Magnet{
        hash: hash,
        trackers: [],
        x_pe_peers: [%Peer{ip: {9, 9, 9, 9}, port: 9999}]
      }

      {:ok, magnet: magnet}
    end

    test "connected first, then x.pe, then the discovered pool with IPv6 ahead", %{
      magnet: magnet
    } do
      v4 = %Peer{ip: {1, 2, 3, 4}, port: 1000}
      v6 = %Peer{ip: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, port: 2000}
      connected = [{{5, 6, 7, 8}, 3000}]

      assert Fetcher.handoff_peers(magnet, connected, peers: [v4, v6]) == [
               %Peer{ip: {5, 6, 7, 8}, port: 3000},
               %Peer{ip: {9, 9, 9, 9}, port: 9999},
               v6,
               v4
             ]
    end

    test "an endpoint known by several sources appears once", %{magnet: magnet} do
      dup = %Peer{ip: {9, 9, 9, 9}, port: 9999, seed: true}

      assert Fetcher.handoff_peers(magnet, [{{9, 9, 9, 9}, 9999}], peers: [dup]) == [
               %Peer{ip: {9, 9, 9, 9}, port: 9999}
             ]
    end

    test "a private torrent keeps only x.pe (BEP 27)", %{magnet: magnet} do
      peers = [%Peer{ip: {1, 2, 3, 4}, port: 1000}]

      assert Fetcher.handoff_peers(magnet, [{{5, 6, 7, 8}, 3000}], peers: peers, private?: true) ==
               magnet.x_pe_peers
    end

    test "the hand-off is bounded", %{magnet: magnet} do
      peers = for n <- 1..500, do: %Peer{ip: {10, 1, div(n, 256), rem(n, 256)}, port: 1000}
      assert length(Fetcher.handoff_peers(magnet, [], peers: peers)) == 200
    end
  end

  describe "Fetcher.release_bootstrap/2" do
    test "keeps the connected endpoints for the download, ahead of later hand-offs", %{
      hash: hash
    } do
      magnet = %Magnet{hash: hash, trackers: [], x_pe_peers: []}
      :ok = Magnet.Bootstrap.ensure(magnet)
      {pid, monitor, _} = register_blocked(hash, {10, 0, 0, 8}, 6881)

      assert :ok = Fetcher.release_bootstrap(magnet, false)
      refute Magnet.Bootstrap.active?(hash)
      :ok = SeedPeers.put(hash, [%Peer{ip: {10, 0, 0, 9}, port: 6881}])

      assert SeedPeers.take(hash) == [
               %Peer{ip: {10, 0, 0, 8}, port: 6881},
               %Peer{ip: {10, 0, 0, 9}, port: 6881}
             ]

      drop(pid, monitor)
      refute Peer.DialBackoff.blocked?(hash, {10, 0, 0, 8}, 6881)
    end

    test "a private torrent stops without carrying peers over (BEP 27)", %{hash: hash} do
      magnet = %Magnet{hash: hash, trackers: [], x_pe_peers: []}
      {pid, monitor, _} = register_blocked(hash, {10, 0, 0, 10}, 6881)

      assert :ok = Fetcher.release_bootstrap(magnet, true)
      assert SeedPeers.take(hash) == []

      drop(pid, monitor)
      refute Peer.DialBackoff.blocked?(hash, {10, 0, 0, 10}, 6881)
    end
  end

  describe "Fetcher.on_metadata_ok/3" do
    test "the download starts from the fetch's peers, not from nothing", %{hash: hash} do
      magnet = %Magnet{hash: hash, trackers: [], x_pe_peers: []}
      :ok = Magnet.Bootstrap.ensure(magnet)
      {pid, monitor, _} = register_blocked(hash, {10, 0, 0, 6}, 6881)
      discovered = %Peer{ip: {10, 0, 0, 7}, port: 6881}

      path = Fetcher.torrent_path(hash)
      on_exit(fn -> File.rm(path) end)
      assert :ok = Fetcher.on_metadata_ok(magnet, path, peers: [discovered])
      refute Magnet.Bootstrap.active?(hash)

      assert SeedPeers.take(hash) == [%Peer{ip: {10, 0, 0, 6}, port: 6881}, discovered]

      drop(pid, monitor)
      refute Peer.DialBackoff.blocked?(hash, {10, 0, 0, 6}, 6881)
    end
  end
end

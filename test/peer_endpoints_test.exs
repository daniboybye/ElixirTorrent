defmodule PeerEndpointsTest do
  use ExUnit.Case, async: false

  @hash :crypto.strong_rand_bytes(20)

  setup do
    unless Process.whereis(Peer.Endpoints) do
      {:ok, _pid} = start_supervised(Peer.Endpoints)
    end

    :ok
  end

  test "registered?/3 tracks live peer processes" do
    peer = spawn(fn -> receive do :stop -> :ok end end)

    refute Peer.Endpoints.registered?(@hash, {9, 9, 9, 9}, 6881)

    :ok = Peer.Endpoints.register(@hash, {9, 9, 9, 9}, 6881, peer)
    assert Peer.Endpoints.registered?(@hash, {9, 9, 9, 9}, 6881)

    Process.exit(peer, :kill)
    Process.sleep(20)

    refute Peer.Endpoints.registered?(@hash, {9, 9, 9, 9}, 6881)
  end

  test "list/1 returns registered endpoints" do
    peer_a = spawn(fn -> receive do :stop -> :ok end end)
    peer_b = spawn(fn -> receive do :stop -> :ok end end)

    :ok = Peer.Endpoints.register(@hash, {1, 2, 3, 4}, 6881, peer_a)
    :ok = Peer.Endpoints.register(@hash, {5, 6, 7, 8}, 6882, peer_b)

    endpoints = Peer.Endpoints.list(@hash) |> MapSet.new()
    assert MapSet.equal?(endpoints, MapSet.new([{{1, 2, 3, 4}, 6881}, {{5, 6, 7, 8}, 6882}]))

    Process.exit(peer_a, :kill)
    Process.exit(peer_b, :kill)
  end
end

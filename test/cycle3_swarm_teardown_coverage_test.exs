defmodule Cycle3SwarmTeardownCoverageTest do
  @moduledoc """
  Coverage for swarm teardown and for the seed-peer carry-over cache.

  Disconnecting a swarm has to work while the torrent is already coming down —
  the supervisor it enumerates may be gone by the time the walk starts — and the
  seed-peer cache is created lazily because it outlives the `PeerDiscovery`
  supervisor that would normally own it.
  """
  use ExUnit.Case, async: false

  alias PeerDiscovery.SeedPeers

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "Torrent.Swarm.disconnect_all/1" do
    test "walks every connected peer" do
      hash = new_hash()
      sup = start_swarm(hash)

      {:ok, _} =
        DynamicSupervisor.start_child(sup, %{
          id: make_ref(),
          start: {Agent, :start_link, [fn -> :peer end]},
          restart: :temporary
        })

      assert :ok = Torrent.Swarm.disconnect_all(hash)
    end

    test "is a no-op once the swarm supervisor is gone" do
      assert :ok = Torrent.Swarm.disconnect_all(new_hash())
    end
  end

  describe "PeerDiscovery.SeedPeers" do
    test "carries peers across a torrent restart and merges repeated puts" do
      hash = new_hash()
      on_exit(fn -> SeedPeers.take(hash) end)

      assert :ok = SeedPeers.put(hash, [])
      assert :ok = SeedPeers.put(hash, [peer({192, 0, 2, 21}, 6881)])
      # A second put must extend the carried list, not replace it.
      assert :ok = SeedPeers.put(hash, [peer({192, 0, 2, 22}, 6882)])

      taken = SeedPeers.take(hash)
      assert length(taken) == 2
      # take/1 is destructive: the peers are handed to exactly one restart.
      assert SeedPeers.take(hash) == []
    end
  end

  describe "Torrent.Downloads" do
    test "piece_has_in_flight?/2 fails closed for a torrent that is not running" do
      refute Torrent.Downloads.piece_has_in_flight?(new_hash(), 0)
    end

    test "active_indices/1 is empty for a torrent that is not running" do
      assert Torrent.Downloads.active_indices(new_hash()) == []
    end
  end

  ## helpers -----------------------------------------------------------------

  defp new_hash, do: :crypto.strong_rand_bytes(20)

  defp peer(ip, port), do: %Peer{ip: ip, port: port}

  defp start_swarm(hash) do
    {:ok, pid} =
      DynamicSupervisor.start_link(
        name: {:via, Registry, {Registry, {hash, Torrent.Swarm}}},
        strategy: :one_for_one,
        max_restarts: 0
      )

    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 500) end)
    pid
  end
end

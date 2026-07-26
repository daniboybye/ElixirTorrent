defmodule Peer.DialStatsTest do
  use ExUnit.Case, async: false

  alias Acceptor.Connection.Handshakes
  alias Peer.DialStats

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    if :ets.info(:peer_dial_stats) != :undefined, do: :ets.delete_all_objects(:peer_dial_stats)
    Application.delete_env(:elixir_torrent, :v6_dial_cap)
    Application.delete_env(:elixir_torrent, :dial_family_cap)
    :ok
  end

  defp hash, do: :crypto.strong_rand_bytes(20)

  defp family(%Peer{ip: ip}) when tuple_size(ip) == 8, do: :inet6
  defp family(%Peer{}), do: :inet

  defp count_by_family(peers) do
    Enum.reduce(peers, %{inet: 0, inet6: 0}, fn peer, acc ->
      Map.update!(acc, family(peer), &(&1 + 1))
    end)
  end

  defp v6_capable?, do: Acceptor.primary_ips().inet6 != nil

  describe "throttle_worthy?/2" do
    test "not worthy before a meaningful sample of attempts" do
      h = hash()
      DialStats.record(h, :inet, 0, 4)
      refute DialStats.throttle_worthy?(h, :inet)
    end

    test "worthy once a real sample has zero successes" do
      h = hash()
      DialStats.record(h, :inet6, 0, 40)
      assert DialStats.throttle_worthy?(h, :inet6)
    end

    test "worthy for a low non-zero trickle over a large sample (the 1.3% v4 case)" do
      h = hash()
      # 1 ok / 60 = ~1.6%, i.e. effectively dead — matches the live IPv4 reading.
      DialStats.record(h, :inet, 1, 59)
      assert DialStats.throttle_worthy?(h, :inet)
    end

    test "not worthy once success rate clears the threshold (the 25% v6 case)" do
      h = hash()
      DialStats.record(h, :inet6, 13, 39)
      refute DialStats.throttle_worthy?(h, :inet6)
    end

    test "prefer_inet6? when v6 success rate is at least 2× v4 with enough samples" do
      h = hash()
      # Live CGNAT shape: v4 ~1.6%, v6 ~25%.
      DialStats.record(h, :inet, 1, 59)
      DialStats.record(h, :inet6, 13, 39)
      assert DialStats.prefer_inet6?(h)
    end

    test "prefer_inet6? false when families are comparable or under-sampled" do
      h = hash()
      DialStats.record(h, :inet, 10, 30)
      DialStats.record(h, :inet6, 13, 39)
      refute DialStats.prefer_inet6?(h)

      h2 = hash()
      DialStats.record(h2, :inet, 0, 4)
      DialStats.record(h2, :inet6, 10, 30)
      refute DialStats.prefer_inet6?(h2)
    end

    test "prefer_inet6? respects the config gate" do
      h = hash()
      DialStats.record(h, :inet, 1, 59)
      DialStats.record(h, :inet6, 13, 39)
      Application.put_env(:elixir_torrent, :dial_family_cap, false)
      refute DialStats.prefer_inet6?(h)
    end

    test "at the minimum sample, a single success is enough to spare a family" do
      h = hash()
      DialStats.record(h, :inet, 1, 11)
      refute DialStats.throttle_worthy?(h, :inet)
    end

    test "a family's judgment is independent of the other family's stats" do
      h = hash()
      DialStats.record(h, :inet, 0, 100)
      assert DialStats.throttle_worthy?(h, :inet)
      refute DialStats.throttle_worthy?(h, :inet6)
    end

    test "judgment is per-torrent — one dead swarm does not throttle another" do
      dead = hash()
      live = hash()
      DialStats.record(dead, :inet, 0, 40)
      assert DialStats.throttle_worthy?(dead, :inet)
      refute DialStats.throttle_worthy?(live, :inet)
    end

    test "can be disabled by the canonical :dial_family_cap config" do
      h = hash()
      DialStats.record(h, :inet, 0, 40)
      Application.put_env(:elixir_torrent, :dial_family_cap, false)
      refute DialStats.throttle_worthy?(h, :inet)
    end

    test "the legacy :v6_dial_cap config still disables the whole throttle" do
      h = hash()
      DialStats.record(h, :inet, 0, 40)
      Application.put_env(:elixir_torrent, :v6_dial_cap, false)
      refute DialStats.throttle_worthy?(h, :inet)
    end
  end

  describe "decay stability (no flapping below the sample gate)" do
    test "a single decay tick keeps a just-over-threshold family throttle-worthy" do
      h = hash()
      # 14 attempts, all failures — just over the sample gate of 12.
      DialStats.record(h, :inet, 0, 14)
      assert DialStats.throttle_worthy?(h, :inet)

      # Trigger one decay pass synchronously. The gentle ×7/8 step takes 14 -> 12,
      # which is still >= the sample gate, so the family stays throttle-worthy.
      # (Under the old hard halving this dropped 14 -> 7, fell under the gate, and
      # un-throttled a still-dead family for a full batch — the flap we fixed.)
      pid = Process.whereis(Peer.DialStats)
      send(pid, :decay)
      _ = :sys.get_state(pid)

      assert DialStats.counts(h, :inet) == {0, 12}
      assert DialStats.throttle_worthy?(h, :inet)
    end
  end

  describe "record/4 and counts/2" do
    test "accumulates ok/fail counts per family" do
      h = hash()
      DialStats.record(h, :inet6, 2, 3)
      DialStats.record(h, :inet6, 1, 1)
      assert DialStats.counts(h, :inet6) == {3, 4}
    end

    test "a zero/zero record is a no-op" do
      h = hash()
      assert DialStats.record(h, :inet6, 0, 0) == :ok
      assert DialStats.counts(h, :inet6) == {0, 0}
    end
  end

  defp swarm_via(hash), do: {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

  defp start_swarm_with_connected(hash, n) when n >= 0 do
    name = swarm_via(hash)

    case DynamicSupervisor.start_link(name: name, strategy: :one_for_one) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    current = Torrent.Swarm.count(hash)

    for _ <- 1..max(n - current, 0) do
      spec = blocked_swarm_child_spec(:dummy_peer)
      {:ok, _} = DynamicSupervisor.start_child(name, spec)
    end

    assert Torrent.Swarm.count(hash) == n
  end

  defp blocked_swarm_child_spec(id) do
    %{
      id: id,
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]},
      restart: :temporary
    }
  end

  describe "select_peers_to_dial/3 — family throttling" do
    defp v4_peers(range),
      do: for(n <- range, do: %Peer{ip: {1, 0, 0, rem(n, 250)}, port: 6000 + n})

    defp v6_peers(range),
      do: for(n <- range, do: %Peer{ip: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, n}, port: 7000 + n})

    test "throttles v4 to a probe when v4 is wasteful and v6 is a viable alternative" do
      if v6_capable?() do
        h = hash()
        start_swarm_with_connected(h, 12)
        # v4 dead (~1.6%) but v6 only modestly ahead (~3%) — above the wasteful
        # cutoff yet below the 2× bar for prefer_inet6?, so throttle_family applies.
        DialStats.record(h, :inet, 1, 59)
        DialStats.record(h, :inet6, 1, 32)

        selected = Handshakes.select_peers_to_dial(v4_peers(1..40) ++ v6_peers(1..40), h, 40)

        assert length(selected) == 40
        assert count_by_family(selected) == %{inet: 4, inet6: 36}
      else
        assert true
      end
    end

    test "throttles v6 to a probe when v6 is wasteful and v4 is a viable alternative" do
      if v6_capable?() do
        h = hash()
        start_swarm_with_connected(h, 12)
        DialStats.record(h, :inet6, 0, 40)
        DialStats.record(h, :inet, 20, 20)

        selected = Handshakes.select_peers_to_dial(v4_peers(1..40) ++ v6_peers(1..40), h, 40)

        assert length(selected) == 40
        assert count_by_family(selected) == %{inet: 36, inet6: 4}
      else
        assert true
      end
    end

    test "caps wasteful v4-only batch to a probe once connected — do not burn the whole budget on dead v4" do
      h = hash()
      start_swarm_with_connected(h, 1)
      DialStats.record(h, :inet, 0, 40)

      selected = Handshakes.select_peers_to_dial(v4_peers(1..40), h, 40)

      assert length(selected) == 4
      assert count_by_family(selected) == %{inet: 4, inet6: 0}
    end

    test "connected==0 with wasteful v4 still uses full batch (lottery width after tracker kick)" do
      h = hash()
      # Simulates live E622: prior 40-timeout wave marked v4 wasteful, but fresh
      # tracker announce with connected==0 must not stay stuck at @dial_probe (4).
      DialStats.record(h, :inet, 0, 40)
      assert DialStats.throttle_worthy?(h, :inet)

      selected = Handshakes.select_peers_to_dial(v4_peers(1..40), h, 40)

      assert length(selected) == 40
      assert count_by_family(selected) == %{inet: 40, inet6: 0}
    end

    test "caps critical sole v4 to a probe when a few peers are already connected" do
      h = hash()
      start_swarm_with_connected(h, 5)

      selected = Handshakes.select_peers_to_dial(v4_peers(1..40), h, 40)

      assert length(selected) == 4
      assert count_by_family(selected) == %{inet: 4, inet6: 0}
      refute DialStats.throttle_worthy?(h, :inet)
    end

    test "uses full batch for critical sole v4 at connected==0 (fresh tracker kick)" do
      h = hash()
      # No Swarm process → Swarm.count/1 returns 0 (critical tier, first dial wave).
      selected = Handshakes.select_peers_to_dial(v4_peers(1..40), h, 40)

      assert length(selected) == 40
      assert count_by_family(selected) == %{inet: 40, inet6: 0}
      refute DialStats.throttle_worthy?(h, :inet)
    end

    test "sole v6-only swarm still uses the full batch even when v6 reads wasteful" do
      if v6_capable?() do
        h = hash()
        DialStats.record(h, :inet6, 0, 40)

        selected = Handshakes.select_peers_to_dial(v6_peers(1..40), h, 40)

        assert length(selected) == 40
        assert count_by_family(selected) == %{inet: 0, inet6: 40}
      else
        assert true
      end
    end

    test "critical scarcity (< 12 connected) prefers v6 before v4" do
      if v6_capable?() do
        h = hash()
        selected = Handshakes.select_peers_to_dial(v4_peers(1..20) ++ v6_peers(1..20), h, 10)

        assert length(selected) == 10
        assert count_by_family(selected) == %{inet: 0, inet6: 10}
      else
        assert true
      end
    end

    test "leaves a healthy mixed batch untouched, filling from both families" do
      if v6_capable?() do
        h = hash()
        start_swarm_with_connected(h, 12)
        selected = Handshakes.select_peers_to_dial(v4_peers(1..40) ++ v6_peers(1..40), h, 40)

        assert length(selected) == 40
        counts = count_by_family(selected)
        assert counts.inet > 0 and counts.inet6 > 0
      else
        assert true
      end
    end

    test "biases v6-heavy when DialStats show v6 clearly outperforms v4 (non-critical)" do
      if v6_capable?() do
        h = hash()
        start_swarm_with_connected(h, 12)
        DialStats.record(h, :inet, 1, 59)
        DialStats.record(h, :inet6, 13, 39)

        selected = Handshakes.select_peers_to_dial(v4_peers(1..40) ++ v6_peers(1..40), h, 40)

        assert length(selected) == 40
        assert count_by_family(selected) == %{inet: 10, inet6: 30}
      else
        assert true
      end
    end
  end
end

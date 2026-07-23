defmodule HandshakesTest do
  use ExUnit.Case, async: false

  alias Acceptor.Connection.Handshakes
  alias Peer.DialStats

  @hash :crypto.strong_rand_bytes(20)

  setup do
    if :ets.info(:peer_dial_stats) != :undefined, do: :ets.delete_all_objects(:peer_dial_stats)
    :ok
  end

  describe "dial_transports/2" do
    test "IPv6 always tries TCP first" do
      ipv6 = {8193, 45073, 14364, 48314, 5656, 30719, 65108, 21111}
      assert Handshakes.dial_transports(ipv6, @hash) == [:tcp, :utp]
    end

    test "IPv4 tries TCP first when v4 is not throttle-worthy" do
      refute DialStats.throttle_worthy?(@hash, :inet)
      assert Handshakes.dial_transports({1, 2, 3, 4}, @hash) == [:tcp, :utp]
    end

    test "IPv4 tries uTP first when v4 dials are proven wasteful" do
      DialStats.record(@hash, :inet, 0, 40)
      assert DialStats.throttle_worthy?(@hash, :inet)
      assert Handshakes.dial_transports({1, 2, 3, 4}, @hash) == [:utp, :tcp]
    end
  end

  describe "connectable_peer?/1" do
    test "rejects non-routable addresses" do
      refute Handshakes.connectable_peer?(%Peer{ip: {127, 0, 0, 1}, port: 6881})
      refute Handshakes.connectable_peer?(%Peer{ip: {0, 0, 0, 0}, port: 6881})
      refute Handshakes.connectable_peer?(%Peer{ip: {169, 254, 1, 1}, port: 6881})
    end

    test "accepts public IPv4" do
      assert Handshakes.connectable_peer?(%Peer{ip: {1, 2, 3, 4}, port: 6881})
    end

    test "skips IPv6 when host has no global IPv6" do
      ipv6 = {8193, 45073, 14364, 48314, 5656, 30719, 65108, 21111}

      if Acceptor.primary_ips().inet6 == nil do
        refute Handshakes.connectable_peer?(%Peer{ip: ipv6, port: 6881})
      else
        assert Handshakes.connectable_peer?(%Peer{ip: ipv6, port: 6881})
      end
    end
  end

  describe "local_endpoint?/3" do
    test "matches (any-of-our-globals, listen_port)" do
      %{inet: v4, inet6_all: v6_all} = Acceptor.all_global_ips()
      listen = Acceptor.port()

      if v4 != nil, do: assert(Handshakes.local_endpoint?(v4, listen, listen))

      case v6_all do
        [v6 | _] -> assert Handshakes.local_endpoint?(v6, listen, listen)
        [] -> :ok
      end
    end

    test "matches a peer whose (ip, port) equals a STUN reflexive observation" do
      # Simulate a NAT-mapped external endpoint that a tracker/DHT might echo
      # back to us. Reflexives are stashed in :persistent_term by port_mapper
      # after each detect run; overwrite for this test then restore.
      prev = NAT.Stun.reflexives()
      NAT.Stun.put_reflexives([{{198, 51, 100, 7}, 40_000}])

      try do
        assert Handshakes.local_endpoint?({198, 51, 100, 7}, 40_000, 6881)
        # Reflexive IP + our listen port also counts (CGNAT/TCP path — the
        # tracker echoed our announce back, port matches what we announced).
        assert Handshakes.local_endpoint?({198, 51, 100, 7}, 6881, 6881)
        # Reflexive IP with an unrelated port is a different peer (many
        # subscribers share one CGNAT IP), so only the (ip, port) or (ip,
        # listen_port) combinations count.
        refute Handshakes.local_endpoint?({198, 51, 100, 7}, 40_001, 6881)
      after
        NAT.Stun.put_reflexives(prev)
      end
    end

    test "does not match unrelated public peers" do
      refute Handshakes.local_endpoint?({8, 8, 8, 8}, 6881, 6881)
    end
  end

  describe "select_peers_to_dial/2" do
    test "caps peers per batch" do
      # Non-critical (>= 12 connected) so sole v4 is not probe-capped — this
      # asserts the batch-size ceiling only.
      hash = @hash
      name = {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

      case DynamicSupervisor.start_link(name: name, strategy: :one_for_one) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      for _ <- 1..12 do
        spec = %{
          id: :dummy_peer,
          start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]},
          restart: :temporary
        }

        {:ok, _} = DynamicSupervisor.start_child(name, spec)
      end

      peers =
        for n <- 1..50 do
          %Peer{ip: {1, 0, 0, rem(n, 250)}, port: 6000 + n}
        end

      selected = Handshakes.select_peers_to_dial(peers, hash, 40)
      assert length(selected) == 40
    end
  end
end

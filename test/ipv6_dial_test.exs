defmodule IPv6DialTest do
  use ExUnit.Case, async: true

  alias Acceptor.Connection.Handshakes

  @hash :crypto.strong_rand_bytes(20)
  @remote_ipv6 {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 0x0042}

  describe "local_endpoint?/3" do
    test "rejects our own listen address on the listen port" do
      %{inet: v4, inet6_all: v6_all} = Acceptor.all_global_ips()
      port = Acceptor.port()

      if v4 do
        assert Handshakes.local_endpoint?(v4, port, port)
        refute Handshakes.connectable_peer?(%Peer{ip: v4, port: port}, port)
      end

      for ip <- v6_all do
        assert Handshakes.local_endpoint?(ip, port, port)
        refute Handshakes.connectable_peer?(%Peer{ip: ip, port: port}, port)
      end
    end

    test "allows our address on a different port" do
      %{inet: v4} = Acceptor.all_global_ips()
      listen = Acceptor.port()

      if v4 do
        refute Handshakes.local_endpoint?(v4, listen + 1, listen)
        assert Handshakes.connectable_peer?(%Peer{ip: v4, port: listen + 1}, listen)
      end
    end

    test "rejects same-/64 IPv6 at listen port with a different host-id (tracker privacy echo)" do
      if Acceptor.primary_ips().inet6 != nil do
        %{inet6_all: v6_all} = Acceptor.all_global_ips()
        listen = Acceptor.port()

        case v6_all do
          [{a, b, c, d, _, _, _, _} | _] ->
            # Same /64 as our global, different interface identifier — BEP-7 trackers
            # often echo the announcer; privacy extensions rotate the host-id.
            echo = {a, b, c, d, 0, 0, 0, 0xBEEF}
            refute echo in v6_all
            assert Handshakes.local_endpoint?(echo, listen, listen)
            refute Handshakes.connectable_peer?(%Peer{ip: echo, port: listen}, listen)

          [] ->
            :ok
        end
      else
        :ok
      end
    end

    test "allows foreign /64 IPv6 at listen port" do
      if Acceptor.primary_ips().inet6 != nil do
        listen = Acceptor.port()
        foreign = {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 0x0042}

        refute Handshakes.local_endpoint?(foreign, listen, listen)
        assert Handshakes.connectable_peer?(%Peer{ip: foreign, port: listen}, listen)
      else
        :ok
      end
    end
  end

  describe "select_peers_to_dial/3 IPv6 reservation" do
    test "reserves slots for IPv6 when host has global IPv6" do
      if Acceptor.primary_ips().inet6 == nil do
        :ok
      else
        v4_peers =
          for n <- 1..30 do
            %Peer{ip: {1, 0, 0, rem(n, 250) + 1}, port: 6000 + n}
          end

        v6_peers = [%Peer{ip: @remote_ipv6, port: 9001}]
        selected = Handshakes.select_peers_to_dial(v4_peers ++ v6_peers, @hash, 10)

        assert length(selected) == 10
        assert Enum.any?(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
      end
    end
  end

  describe "KRPC.response_peers/1 compact decoding" do
    alias DHT.{Compact, KRPC}

    test "decodes bare binary values blob with multiple IPv4 peers" do
      blob =
        Compact.encode_peer({1, 2, 3, 4}, 6881) <>
          Compact.encode_peer({5, 6, 7, 8}, 6882)

      assert length(KRPC.response_peers(%{values: blob})) == 2
    end

    test "decodes list element with multiple IPv6 peers" do
      bin =
        <<0x26, 0x02, 0x00, 0x2d, 0x40, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x42,
          0x1A, 0xE1, 0x26, 0x02, 0x00, 0x2d, 0x40, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0,
          0x00, 0x43, 0x1A, 0xE2>>

      peers = KRPC.response_peers(%{values: [bin]})
      assert length(peers) == 2
      assert Enum.all?(peers, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
    end
  end

  describe "DHT.cap_lookup_peers/2" do
    test "reserves slots for IPv6 peers under the cap" do
      v4 = for n <- 1..80, do: %Peer{ip: {1, 0, 0, rem(n, 250) + 1}, port: 6000 + n}

      v6 = [
        %Peer{ip: {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 0x0001}, port: 6881},
        %Peer{ip: {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 0x0002}, port: 6882}
      ]

      capped = DHT.cap_lookup_peers(v4 ++ v6, 100)
      assert length(capped) == 82
      assert Enum.count(capped, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end) == 2
    end
  end
end

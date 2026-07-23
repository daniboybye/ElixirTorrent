defmodule IPv6AnnounceTest do
  use ExUnit.Case, async: true

  alias DHT.{Compact, PeerStore, Token}

  @connection_id :crypto.strong_rand_bytes(8)
  @transaction_id <<0xDE, 0xAD, 0xBE, 0xEF>>
  @hash :crypto.strong_rand_bytes(20)
  @stats {0, 0, 1, 0}

  describe "UDP tracker IPv6 announce encoding (BEP 15)" do
    test "encode_udp_announce_for_test uses ip_field=0 for inet6" do
      packet =
        Tracker.encode_udp_announce_for_test(@connection_id, @transaction_id, @hash, @stats, :inet6)
        |> IO.iodata_to_binary()

      # ip_field at byte offset 84 in the 98-byte BEP 15 announce packet
      assert byte_size(packet) == 98
      <<_::binary-size(84), 0::32, _key::32, _rest::binary>> = packet
    end

    test "encode_udp_announce_for_test embeds IPv4 in ip_field for inet" do
      packet =
        Tracker.encode_udp_announce_for_test(@connection_id, @transaction_id, @hash, @stats, :inet)
        |> IO.iodata_to_binary()

      # ip_field at byte offset 84 in the 98-byte BEP 15 announce packet
      <<_::binary-size(84), ip_field::32, _key::32, _rest::binary>> = packet

      case Acceptor.ipv4_binary() do
        <<a, b, c, d>> ->
          assert ip_field == :binary.decode_unsigned(<<a, b, c, d>>)

        nil ->
          assert ip_field == 0
      end
    end
  end

  describe "resolve_hosts/1 dual-family DNS" do
    test "returns both A and AAAA for localhost when available" do
      case Tracker.resolve_hosts("localhost") do
        {:ok, hosts} ->
          families = Enum.map(hosts, &elem(&1, 1)) |> Enum.uniq()
          assert :inet in families

        {:error, :nxdomain} ->
          # Some CI environments lack localhost DNS; skip assertion.
          :ok
      end
    end

    test "fails only when both A and AAAA resolution fail" do
      assert {:error, :nxdomain} = Tracker.resolve_hosts("this-host-should-not-exist.invalid.")

      assert Tracker.expected_dns_failure?(:nxdomain)
      assert Tracker.expected_dns_failure?(:timeout)
      refute Tracker.expected_dns_failure?(:einval)
    end
  end

  describe "DHT compact IPv6 node encoding (BEP 32)" do
    @node_id :crypto.strong_rand_bytes(20)
    @ip6 {0x2A01, 0x05A8, 0, 0, 0, 0, 0, 0x0001}
    @port 6881

    test "encode_nodes6/1 round-trips with decode_nodes6/1" do
      contact = %{id: @node_id, ip: @ip6, port: @port}
      encoded = Compact.encode_nodes6([contact])

      assert byte_size(encoded) == Compact.node_info6_size()
      assert [decoded] = Compact.decode_nodes6(encoded)
      assert decoded.id == @node_id
      assert decoded.ip == @ip6
      assert decoded.port == @port
    end

    test "encode_node6/3 produces 38-byte records" do
      encoded = Compact.encode_node6(@node_id, @ip6, @port)
      assert byte_size(encoded) == 38
    end
  end

  describe "DHT announce_peer stores IPv6 peers (BEP 5 § server)" do
    test "PeerStore retains peer announced from IPv6 source address" do
      hash = :crypto.strong_rand_bytes(20)
      ip6 = {0x2A01, 0x05A8, 0xABCD, 0x1234, 0x5678, 0x9ABC, 0xDEF0, 0x1234}
      peer = %Peer{ip: ip6, port: 6882}

      store = PeerStore.put(%{}, hash, peer)
      assert [%Peer{ip: ^ip6, port: 6882}] = PeerStore.get(store, hash)
    end

    test "Token.valid?/3 accepts tokens issued to IPv6 requester" do
      ip6 = {0x2A01, 0x05A8, 0, 0, 0, 0, 0, 1}
      store = Token.new(now_ms: 1_000_000)
      token = Token.issue(store, ip6)
      assert Token.valid?(store, ip6, token, now_ms: 1_000_000)
    end
  end

  describe "KRPC nodes6 response encoding" do
    alias DHT.KRPC

    test "encode_response includes nodes6 field when present" do
      node_id = :crypto.strong_rand_bytes(20)
      ip6 = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
      nodes6 = Compact.encode_nodes6([%{id: node_id, ip: ip6, port: 6881}])

      packet =
        KRPC.encode_response(%{
          transaction_id: <<1, 2>>,
          node_id: :crypto.strong_rand_bytes(20),
          nodes6: nodes6
        })

      assert {:ok, {:response, decoded}} = KRPC.decode(packet)
      assert decoded.nodes6 == nodes6
      assert length(Compact.decode_nodes6(decoded.nodes6)) == 1
    end
  end
end

defmodule HTTPTrackerIPv6Test do
  use ExUnit.Case, async: true

  alias Tracker.UDP

  @hash :crypto.strong_rand_bytes(20)

  describe "BEP 7 HTTP announce query" do
    test "build_http_announce_query includes ip and ipv6 when global addresses exist" do
      query =
        Tracker.build_http_announce_query(@hash, 0, 0, 16_384, Torrent.started())

      assert Map.has_key?(query, "info_hash")
      assert Map.has_key?(query, "port")

      case Acceptor.primary_ips() do
        %{inet: {a, b, c, d}} ->
          assert query["ip"] == <<a, b, c, d>>

        %{inet: nil} ->
          refute Map.has_key?(query, "ip")
      end

      case Acceptor.primary_ips() do
        %{inet6: {s1, s2, s3, s4, s5, s6, s7, s8}} ->
          assert query["ipv6"] ==
                   <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>>

        %{inet6: nil} ->
          refute Map.has_key?(query, "ipv6")
      end
    end
  end

  describe "BEP 7 peers6 parsing" do
    test "to_peers_v6 decodes 18-byte compact IPv6 peer records" do
      bin =
        <<0x26, 0x02, 0x00, 0x2d, 0x40, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x42,
          0x1A, 0xE1>>

      peers = UDP.parse_compact_peers(bin, :inet6)
      assert length(peers) == 1
      assert hd(peers).port == 6881
      assert tuple_size(hd(peers).ip) == 8
    end
  end

  describe "BEP 32 DHT compact IPv6 peers" do
    test "decode_ipv6_peers parses 18-byte values entries" do
      bin =
        <<0x26, 0x02, 0x00, 0x2d, 0x40, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x42,
          0x1A, 0xE1>>

      peers = DHT.Compact.decode_ipv6_peers(bin)
      assert length(peers) == 1
      assert hd(peers).port == 6881
    end
  end
end

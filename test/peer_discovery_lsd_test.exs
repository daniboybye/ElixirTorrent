defmodule PeerDiscoveryLSDTest do
  use ExUnit.Case, async: true

  alias PeerDiscovery.LSD

  # Two arbitrary 20-byte SHA-1-shaped hashes.
  @hash1 <<0x12, 0xED, 0xB7, 0xF1, 0x55, 0x0B, 0xBB, 0xED, 0x5F, 0xFD, 0xDE, 0xCF, 0xDC, 0x29,
           0x03, 0xFB, 0x69, 0xA9, 0xA4, 0x8D>>
  @hash2 <<0x9F, 0xE8, 0x9E, 0x06, 0x5A, 0xF8, 0x4A, 0x21, 0x51, 0x32, 0x12, 0x80, 0xCA, 0xB2,
           0xEC, 0x36, 0x63, 0xE8, 0xB9, 0x05>>

  test "build_message emits a well-formed BT-SEARCH packet with multiple Infohash lines" do
    packet = IO.iodata_to_binary(LSD.build_message([@hash1, @hash2], 6881, "abc123"))

    assert String.starts_with?(packet, "BT-SEARCH * HTTP/1.1\r\n")
    assert String.ends_with?(packet, "\r\n\r\n")
    assert packet =~ "Host: 239.192.152.143:6771\r\n"
    assert packet =~ "Port: 6881\r\n"
    assert packet =~ "Infohash: #{Torrent.hex_encoded_hash(@hash1)}\r\n"
    assert packet =~ "Infohash: #{Torrent.hex_encoded_hash(@hash2)}\r\n"
    assert packet =~ "cookie: abc123\r\n"
  end

  test "IPv6 announce is built for every interface with the BEP 14 group" do
    interfaces = %{inet: [{192, 168, 1, 10}, {10, 0, 0, 8}], inet6: [4, 9]}

    datagrams = LSD.announce_datagrams([@hash1], 6881, "v6-cookie", interfaces)

    assert [
             {:inet6, 4, {0xFF15, 0, 0, 0, 0, 0, 0xEFC0, 0x988F}, first},
             {:inet6, 9, {0xFF15, 0, 0, 0, 0, 0, 0xEFC0, 0x988F}, second}
           ] = Enum.filter(datagrams, &(elem(&1, 0) == :inet6))

    for payload <- [first, second] do
      packet = IO.iodata_to_binary(payload)
      assert packet =~ "Host: [ff15::efc0:988f]:6771\r\n"

      assert {:ok, %{hashes: [@hash1], port: 6881, cookie: "v6-cookie"}} =
               LSD.parse_message(packet)
    end

    assert LSD.membership_option(:inet6, 4) ==
             {:add_membership, {{0xFF15, 0, 0, 0, 0, 0, 0xEFC0, 0x988F}, 4}}

    assert LSD.membership_option(:inet6, 9) ==
             {:add_membership, {{0xFF15, 0, 0, 0, 0, 0, 0xEFC0, 0x988F}, 9}}

    assert [
             {:inet, {192, 168, 1, 10}, {239, 192, 152, 143}, _first_payload},
             {:inet, {10, 0, 0, 8}, {239, 192, 152, 143}, _second_payload}
           ] = Enum.filter(datagrams, &(elem(&1, 0) == :inet))
  end

  test "parse_message decodes port + infohashes + cookie back out" do
    packet = IO.iodata_to_binary(LSD.build_message([@hash1, @hash2], 6881, "abc123"))

    assert {:ok, decoded} = LSD.parse_message(packet)
    assert decoded.port == 6881
    assert decoded.cookie == "abc123"
    assert decoded.hashes == [@hash1, @hash2]
  end

  test "received IPv6 BT-SEARCH is parsed and our own cookie is deduped" do
    source = {0x2001, 0xDB8, 0, 1, 0, 0, 0, 7}
    packet = IO.iodata_to_binary(LSD.build_message([@hash1], 51_413, "remote", :inet6))

    assert LSD.decode_packet(packet, source, "ours") == [{@hash1, source, 51_413}]
    assert LSD.decode_packet(packet, source, "remote") == []
  end

  test "25 active hashes are spread into at most one announce per minute" do
    hashes = for value <- 1..25, do: :crypto.hash(:sha, <<value>>)

    schedule = LSD.announce_schedule(hashes)

    assert [{0, first}, {60_000, second}] = schedule
    assert length(first) == 20
    assert length(second) == 5
    assert Enum.flat_map(schedule, &elem(&1, 1)) == hashes

    offsets = Enum.map(schedule, &elem(&1, 0))

    assert Enum.chunk_every(offsets, 2, 1, :discard)
           |> Enum.all?(fn [a, b] -> b - a >= 60_000 end)

    assert LSD.next_cycle_delay(List.last(offsets)) == 240_000
    assert List.last(offsets) + LSD.next_cycle_delay(List.last(offsets)) == 300_000
  end

  test "parse_message rejects non-BT-SEARCH payloads" do
    assert :error = LSD.parse_message("PING")
    assert :error = LSD.parse_message("")
    assert :error = LSD.parse_message(<<0, 1, 2, 3>>)
  end

  test "parse_message rejects messages missing Port or Infohash" do
    only_port = "BT-SEARCH * HTTP/1.1\r\nPort: 6881\r\n\r\n\r\n"

    only_hash =
      "BT-SEARCH * HTTP/1.1\r\nInfohash: #{Torrent.hex_encoded_hash(@hash1)}\r\n\r\n\r\n"

    assert :error = LSD.parse_message(only_port)
    assert :error = LSD.parse_message(only_hash)
  end

  test "parse_message ignores malformed Infohash lines but keeps valid ones" do
    packet =
      "BT-SEARCH * HTTP/1.1\r\n" <>
        "Host: 239.192.152.143:6771\r\n" <>
        "Port: 6881\r\n" <>
        "Infohash: TOO-SHORT\r\n" <>
        "Infohash: #{Torrent.hex_encoded_hash(@hash1)}\r\n" <>
        "cookie: c\r\n\r\n\r\n"

    assert {:ok, decoded} = LSD.parse_message(packet)
    assert decoded.port == 6881
    assert decoded.hashes == [@hash1]
    assert decoded.cookie == "c"
  end

  test "parse_message rejects messages where Port is unparseable (no valid port ⇒ :error)" do
    packet =
      "BT-SEARCH * HTTP/1.1\r\nPort: not-a-number\r\nInfohash: #{Torrent.hex_encoded_hash(@hash1)}\r\n\r\n\r\n"

    assert :error = LSD.parse_message(packet)
  end
end

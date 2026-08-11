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

  test "parse_message rejects out-of-range Port values" do
    for bad <- ["0", "65536", "-1"] do
      packet =
        "BT-SEARCH * HTTP/1.1\r\nPort: #{bad}\r\nInfohash: #{Torrent.hex_encoded_hash(@hash1)}\r\n\r\n\r\n"

      assert :error = LSD.parse_message(packet)
    end
  end

  test "parse_message ignores header lines without a colon separator" do
    packet =
      "BT-SEARCH * HTTP/1.1\r\n" <>
        "Port: 6881\r\n" <>
        "garbage line\r\n" <>
        "Infohash: #{Torrent.hex_encoded_hash(@hash1)}\r\n" <>
        "cookie: x\r\n\r\n\r\n"

    assert {:ok, %{port: 6881, hashes: [@hash1], cookie: "x"}} = LSD.parse_message(packet)
  end

  test "parse_message rejects non-binary payloads" do
    assert :error = LSD.parse_message(123)
    assert :error = LSD.parse_message(nil)
  end

  test "decode_packet drops packets whose cookie matches ours" do
    source = {192, 168, 50, 1}
    packet = IO.iodata_to_binary(LSD.build_message([@hash1], 6881, "same-cookie"))

    assert LSD.decode_packet(packet, source, "same-cookie") == []
  end

  describe "handle_info/2 UDP routing without multicast" do
    setup do
      {:ok, _} = Application.ensure_all_started(:elixir_torrent)
      :ok
    end

    defp lsd_udp_state(cookie \\ "unit-cookie") do
      {:ok, socket} =
        :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_udp.close(socket) end)

      %{
        cookie: cookie,
        sockets: %{inet: socket, inet6: nil},
        interfaces: %{inet: [], inet6: []},
        announce_queue: []
      }
    end

    test "ignores UDP on sockets that are not registered in state" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)
      _announce = start_public_announce!(hash)

      state = lsd_udp_state()
      {:ok, foreign} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(foreign) end)

      packet =
        IO.iodata_to_binary(LSD.build_message([hash], 7777, "remote-cookie"))

      source = {10, 20, 30, 40}

      assert {:noreply, ^state} =
               LSD.handle_info({:udp, foreign, source, 6771, packet}, state)

      refute queued_peer?(hash, source, 7777)
    end

    test "offers parsed peers to ConnectionManager for tracked public torrents" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)
      _announce = start_public_announce!(hash)

      state = lsd_udp_state("our-cookie")
      socket = state.sockets.inet
      source = {172, 16, 0, 9}
      port = 8123

      packet = IO.iodata_to_binary(LSD.build_message([hash], port, "remote-cookie"))

      assert {:noreply, ^state} =
               LSD.handle_info({:udp, socket, source, 6771, packet}, state)

      assert queued_peer?(hash, source, port)
    end

    test "does not offer peers for private torrents (BEP 27)" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)
      _announce = start_private_announce!(hash)

      state = lsd_udp_state("our-cookie")
      socket = state.sockets.inet
      source = {172, 16, 0, 10}
      port = 8124

      packet = IO.iodata_to_binary(LSD.build_message([hash], port, "remote-cookie"))

      assert {:noreply, ^state} =
               LSD.handle_info({:udp, socket, source, 6771, packet}, state)

      refute queued_peer?(hash, source, port)
    end

    test "drops our own multicast loopback via cookie match" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)
      _announce = start_public_announce!(hash)

      state = lsd_udp_state("loop-cookie")
      socket = state.sockets.inet
      source = {127, 0, 0, 1}
      port = 6881

      packet = IO.iodata_to_binary(LSD.build_message([hash], port, "loop-cookie"))

      assert {:noreply, ^state} =
               LSD.handle_info({:udp, socket, source, 6771, packet}, state)

      refute queued_peer?(hash, source, port)
    end

    test "catch-all handle_info leaves state unchanged" do
      state = lsd_udp_state()

      assert {:noreply, ^state} = LSD.handle_info(:unexpected_coverage_probe, state)
    end
  end

  describe "announce/announce_next/refresh without multicast" do
    setup do
      {:ok, _} = Application.ensure_all_started(:elixir_torrent)
      :ok
    end

    defp lsd_loopback_state(opts \\ []) do
      {:ok, socket} =
        :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_udp.close(socket) end)

      %{
        cookie: Keyword.get(opts, :cookie, "lsd-loop-cookie"),
        sockets: %{inet: socket, inet6: nil},
        interfaces: %{inet: [{127, 0, 0, 1}], inet6: []},
        announce_queue: Keyword.get(opts, :announce_queue, [])
      }
    end

    test "handle_info :announce walks active public torrents" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)
      _announce = start_public_announce!(hash)

      state = lsd_loopback_state()

      assert {:noreply, _after_announce} = LSD.handle_info(:announce, state)
    end

    test "handle_info :announce_next drains the queue and schedules the next slice" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)
      _announce = start_public_announce!(hash)

      state =
        lsd_loopback_state(announce_queue: [{0, [hash]}, {60_000, [hash]}])

      assert {:noreply, after_first} = LSD.handle_info(:announce_next, state)
      assert after_first.announce_queue == [{60_000, [hash]}]
    end

    test "handle_info :announce_next with an empty queue schedules the next cycle" do
      state = lsd_loopback_state(announce_queue: [])

      assert {:noreply, ^state} = LSD.handle_info(:announce_next, state)
    end

    test "handle_info :refresh_interfaces reschedules itself and refreshes sockets" do
      state = lsd_loopback_state()

      assert {:noreply, refreshed} = LSD.handle_info(:refresh_interfaces, state)
      assert is_map(refreshed.sockets)
    end

    test "handle_packet survives malformed binary payloads" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)
      _announce = start_public_announce!(hash)

      state = lsd_loopback_state(cookie: "cookie")
      socket = state.sockets.inet

      assert {:noreply, ^state} =
               LSD.handle_info({:udp, socket, {10, 0, 0, 1}, 6771, <<0, 1, 2>>}, state)
    end

    test "terminate closes open sockets" do
      state = lsd_loopback_state()
      socket = state.sockets.inet
      assert :ok = LSD.terminate(:shutdown, state)
      assert {:error, _} = :gen_udp.send(socket, {127, 0, 0, 1}, 6771, "closed")
    end

    test "offer_peer ignores hashes without a live Announce worker" do
      hash = :crypto.strong_rand_bytes(20)
      _manager = start_connection_manager!(hash)

      packet =
        IO.iodata_to_binary(LSD.build_message([hash], 7777, "remote-cookie"))

      state = lsd_loopback_state(cookie: "our-cookie")
      socket = state.sockets.inet
      source = {10, 0, 0, 50}

      assert {:noreply, ^state} =
               LSD.handle_info({:udp, socket, source, 6771, packet}, state)

      refute queued_peer?(hash, source, 7777)
    end
  end

  defp start_connection_manager!(hash) do
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}

    {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)

    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)
    pid
  end

  defp start_public_announce!(hash) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "lsd-public"}},
      left: 1000,
      last_index: 0,
      last_piece_length: 1000
    }

    start_announce!(torrent)
  end

  defp start_private_announce!(hash) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "lsd-private", "private" => 1}},
      left: 1000,
      last_index: 0,
      last_piece_length: 1000
    }

    start_announce!(torrent)
  end

  defp start_announce!(torrent) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

    name = {:via, Registry, {Registry, {torrent.hash, PeerDiscovery.Announce}}}
    {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)

    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)
    pid
  end

  defp queued_peer?(hash, ip, port) do
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}

    case GenServer.whereis(name) do
      nil ->
        false

      pid ->
        state = :sys.get_state(pid)
        Map.has_key?(state.queue, {ip, port})
    end
  end
end

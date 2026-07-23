defmodule UtHolepunchTest do
  use ExUnit.Case, async: true

  alias Peer.{LTEP, UtHolepunch}

  @ipv4 {192, 168, 1, 100}
  @ipv6 {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x0001}
  @port 6882

  describe "BEP 55 codec" do
    test "IPv4 rendezvous round-trip (8 bytes)" do
      encoded = UtHolepunch.encode(:rendezvous, @ipv4, @port)
      assert byte_size(encoded) == 8
      assert <<0, 0, 192, 168, 1, 100, @port::16>> = encoded

      assert {:ok, %{type: :rendezvous, ip: @ipv4, port: @port, err_code: nil}} =
               UtHolepunch.decode(encoded)
    end

    test "IPv4 connect round-trip (8 bytes)" do
      encoded = UtHolepunch.encode(:connect, @ipv4, @port)
      assert byte_size(encoded) == 8
      assert <<1, 0, 192, 168, 1, 100, @port::16>> = encoded

      assert {:ok, %{type: :connect, ip: @ipv4, port: @port}} = UtHolepunch.decode(encoded)
    end

    test "IPv6 connect round-trip (20 bytes)" do
      encoded = UtHolepunch.encode(:connect, @ipv6, @port)
      assert byte_size(encoded) == 20

      assert {:ok, %{type: :connect, ip: @ipv6, port: @port, err_code: nil}} =
               UtHolepunch.decode(encoded)
    end

    test "IPv4 error round-trip (12 bytes with err_code)" do
      encoded = UtHolepunch.encode(:error, @ipv4, @port, err_code: 42)
      assert byte_size(encoded) == 12
      assert <<2, 0, 192, 168, 1, 100, @port::16, 42::32>> = encoded

      assert {:ok, %{type: :error, ip: @ipv4, port: @port, err_code: 42}} =
               UtHolepunch.decode(encoded)
    end

    test "IPv6 error round-trip (24 bytes with err_code)" do
      encoded =
        UtHolepunch.encode(:error, @ipv6, @port, err_code: UtHolepunch.err_not_connected())

      assert byte_size(encoded) == 24

      assert {:ok, %{type: :error, ip: @ipv6, port: @port, err_code: 2}} =
               UtHolepunch.decode(encoded)
    end

    test "rendezvous defaults to no err_code" do
      encoded = UtHolepunch.encode(:rendezvous, @ipv6, @port)
      assert byte_size(encoded) == 20
      assert {:ok, %{type: :rendezvous, ip: @ipv6, err_code: nil}} = UtHolepunch.decode(encoded)
    end

    test "unsupported ip yields error tuple, not a crash" do
      assert {:error, :unsupported_ip} = UtHolepunch.encode(:connect, :not_an_ip, @port)
    end

    test "truncated payload decodes to :error" do
      assert :error = UtHolepunch.decode(<<2, 0, 1, 2, 3>>)
    end
  end

  describe "BEP 55 error codes" do
    test "named codes match the spec values" do
      assert UtHolepunch.err_none() == 0
      assert UtHolepunch.err_no_such_peer() == 1
      assert UtHolepunch.err_not_connected() == 2
      assert UtHolepunch.err_no_support() == 3
      assert UtHolepunch.err_no_self() == 4
    end

    test "err_name/1 labels known and unknown codes" do
      assert UtHolepunch.err_name(2) == "not_connected"
      assert UtHolepunch.err_name(4) == "no_self"
      assert UtHolepunch.err_name(99) == "unknown(99)"
    end
  end

  describe "LTEP extension registration" do
    test "for_peer/1 includes ut_holepunch with local id 3" do
      base_extensions = [Peer.UtHolepunch.Extension, Peer.UtPex.Extension]

      session = LTEP.Session.new(base_extensions)
      assert LTEP.Session.local_extension_id(session, "ut_holepunch") == 3
      assert Peer.UtHolepunch.Extension.local_id() == 3
    end

    test "relay connect payloads encode target and initiator endpoints" do
      target = {{10, 0, 0, 50}, 7777}
      initiator = {{10, 0, 0, 10}, 5555}

      {target_ip, target_port} = target
      {initiator_ip, initiator_port} = initiator

      to_target = UtHolepunch.encode(:connect, target_ip, target_port)
      to_initiator = UtHolepunch.encode(:connect, initiator_ip, initiator_port)

      assert {:ok, %{type: :connect, ip: ^target_ip, port: ^target_port}} =
               UtHolepunch.decode(to_target)

      assert {:ok, %{type: :connect, ip: ^initiator_ip, port: ^initiator_port}} =
               UtHolepunch.decode(to_initiator)
    end
  end
end

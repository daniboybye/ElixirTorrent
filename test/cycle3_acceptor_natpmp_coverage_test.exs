defmodule Cycle3AcceptorNatpmpCoverageTest do
  @moduledoc """
  Coverage for the address-classification rules that decide which of this host's
  addresses we may advertise, and for the NAT-PMP port-mapping codec.

  Which address we publish matters: a tracker/DHT/PEX announce carrying a
  link-local (`fe80::/10`), loopback, CGNAT or multicast address is unroutable,
  so remote peers burn their dial budget on it and never reach us. The classifier
  is normally fed by `:inet.getifaddrs/0`, i.e. by whatever this machine is
  plugged into; `compute_all_global_ips/1` takes that result as an argument so
  the rules can be checked against a synthetic interface list.
  """
  use ExUnit.Case, async: false

  @natpmp_port 5351
  @natpmp_version 0

  describe "Acceptor.compute_all_global_ips/1 classification" do
    test "rejects unroutable IPv4 and IPv6 addresses" do
      ifs = [
        {~c"lo0", [flags: [:up, :running, :loopback], addr: {127, 0, 0, 1}]},
        {~c"junk0",
         [
           flags: [:up, :running],
           addr: {0, 0, 0, 0},
           addr: {169, 254, 3, 4},
           addr: {224, 0, 0, 251},
           addr: {240, 1, 2, 3},
           addr: {0, 0, 0, 0, 0, 0, 0, 0},
           addr: {0, 0, 0, 0, 0, 0, 0, 1},
           addr: {0xFF02, 0, 0, 0, 0, 0, 0, 1},
           addr: {0xFE80, 0, 0, 0, 1, 2, 3, 4},
           addr: :undefined
         ]}
      ]

      assert %{inet: nil, inet6: nil, inet6_all: []} = Acceptor.compute_all_global_ips({:ok, ifs})
    end

    test "keeps the first global IPv4 and every global IPv6" do
      ifs = [
        {~c"en0",
         [
           flags: [:up, :running, :multicast],
           addr: {127, 0, 0, 1},
           addr: {192, 168, 1, 15},
           addr: {0x2A01, 0x5A8, 0x302, 0xD612, 1, 2, 3, 4},
           addr: {0x2A01, 0x5A8, 0x302, 0xD612, 5, 6, 7, 8}
         ]}
      ]

      snapshot = Acceptor.compute_all_global_ips({:ok, ifs})

      assert snapshot.inet == {192, 168, 1, 15}
      assert snapshot.inet6 == {0x2A01, 0x5A8, 0x302, 0xD612, 1, 2, 3, 4}
      assert length(snapshot.inet6_all) == 2
    end

    test "a getifaddrs failure yields an empty snapshot instead of crashing" do
      assert %{
               inet: nil,
               inet6: nil,
               inet6_all: [],
               multicast_interfaces: %{inet: [], inet6: []}
             } = Acceptor.compute_all_global_ips({:error, :eperm})
    end
  end

  describe "Acceptor.multicast_interfaces_from/2" do
    test "skips interfaces that cannot carry LSD multicast" do
      ifs = [
        {~c"lo0", [flags: [:up, :running, :multicast, :loopback], addr: {127, 0, 0, 1}]},
        {~c"utun0", [flags: [:up, :running, :multicast, :pointtopoint], addr: {10, 0, 0, 1}]},
        {~c"down0", [flags: [:multicast], addr: {10, 0, 0, 2}]}
      ]

      assert %{inet: [], inet6: []} =
               Acceptor.multicast_interfaces_from(ifs, fn _ -> {:ok, 1} end)
    end

    test "collects IPv4 addresses and resolves the IPv6 interface index" do
      ifs = [
        {~c"en0",
         [
           flags: [:up, :running, :multicast],
           addr: {192, 168, 1, 15},
           addr: {0x2A01, 0, 0, 0, 0, 0, 0, 1}
         ]}
      ]

      assert %{inet: [{192, 168, 1, 15}], inet6: [4]} =
               Acceptor.multicast_interfaces_from(ifs, fn ~c"en0" -> {:ok, 4} end)
    end

    test "an unresolvable interface name contributes no IPv6 index" do
      ifs = [
        {~c"en9",
         [
           flags: [:up, :running, :multicast],
           addr: {0x2A01, 0, 0, 0, 0, 0, 0, 1}
         ]}
      ]

      assert %{inet: [], inet6: []} =
               Acceptor.multicast_interfaces_from(ifs, fn _ -> {:error, :enodev} end)
    end

    test "addresses that are not multicast-capable are ignored" do
      ifs = [
        {~c"en0",
         [
           flags: [:up, :running, :multicast],
           addr: {0, 0, 0, 0, 0, 0, 0, 0},
           addr: {0, 0, 0, 0, 0, 0, 0, 1},
           addr: {0xFF02, 0, 0, 0, 0, 0, 0, 1}
         ]}
      ]

      assert %{inet: [], inet6: []} =
               Acceptor.multicast_interfaces_from(ifs, fn _ -> {:ok, 4} end)
    end
  end

  describe "Acceptor announce-address helpers with no global address" do
    test "report nil / empty rather than a bogus address" do
      with_ip_snapshot(%{
        inet: nil,
        inet6: nil,
        inet6_all: [],
        multicast_interfaces: %{inet: [], inet6: []}
      })

      assert Acceptor.ipv4_binary() == nil
      assert Acceptor.ipv6_binary() == nil
      assert Acceptor.announcable_ipv6() == []
      # BEP 15: the announce IP field is left as "use my source address".
      assert NAT.NATPMP.default_gateway() == nil
    end

    test "derive the wire encodings from the cached snapshot" do
      v6 = {0x2A01, 0x5A8, 0x302, 0xD612, 1, 2, 3, 4}

      with_ip_snapshot(%{
        inet: {192, 168, 1, 15},
        inet6: v6,
        inet6_all: [v6],
        multicast_interfaces: %{inet: [], inet6: []}
      })

      assert Acceptor.ipv4_binary() == <<192, 168, 1, 15>>

      assert Acceptor.ipv6_binary() ==
               <<0x2A01::16, 0x5A8::16, 0x302::16, 0xD612::16, 1::16, 2::16, 3::16, 4::16>>

      assert Acceptor.announcable_ipv6() == [v6]
      # The gateway heuristic is "same /24, host .1".
      assert NAT.NATPMP.default_gateway() == {192, 168, 1, 1}
    end
  end

  describe "Acceptor UDP sockets" do
    test "open_udp/0 defaults to IPv4" do
      assert {:ok, socket} = Acceptor.open_udp()
      assert {:ok, {_ip, _port}} = :inet.sockname(socket)
      :ok = :gen_udp.close(socket)
    end

    test "binding an address this host does not own fails closed" do
      assert :error = Acceptor.open_udp(:inet, {203, 0, 113, 7})
    end

    test "apply_tcp_performance/1 tolerates a socket that is already gone" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      :ok = :gen_tcp.close(listen)

      assert :ok = Acceptor.apply_tcp_performance(listen)
    end
  end

  describe "NAT.NATPMP codec" do
    test "decodes a successful mapping response" do
      packet = <<@natpmp_version, 2, 0::16, 6881::16, 41_234::16, 7200::32>>
      assert {:ok, 6881, 41_234, 7200} = NAT.NATPMP.decode_map_response(packet)
    end

    test "surfaces the gateway's result code" do
      # Result code 2 is "network failure" in RFC 6886 — the router saw the
      # request but has no usable uplink, so the mapping must not be trusted.
      packet = <<@natpmp_version, 130, 2::16, 0::16, 0::16, 0::32>>
      assert {:error, {:natpmp, 2}} = NAT.NATPMP.decode_map_response(packet)
    end

    test "rejects a truncated or foreign datagram" do
      assert {:error, :invalid_response} = NAT.NATPMP.decode_map_response(<<0, 1>>)
      assert {:error, :invalid_response} = NAT.NATPMP.decode_map_response(<<>>)
    end
  end

  describe "NAT.NATPMP.map_port/4 against a local gateway" do
    setup do
      case :gen_udp.open(@natpmp_port, [
             :binary,
             active: false,
             reuseaddr: true,
             ip: {127, 0, 0, 1}
           ]) do
        {:ok, socket} ->
          on_exit(fn -> :gen_udp.close(socket) end)
          {:ok, gateway: socket}

        {:error, reason} ->
          {:ok, gateway: nil, skip_reason: reason}
      end
    end

    test "maps a port and returns the external port and lifetime", %{gateway: gateway} do
      assert gateway != nil, "UDP 5351 is already in use on this host"

      with_ip_snapshot(%{
        inet: {127, 0, 0, 1},
        inet6: nil,
        inet6_all: [],
        multicast_interfaces: %{inet: [], inet6: []}
      })

      # The engine's own NAT.PortMapper may be probing 5351 at the same time, so
      # the responder answers every datagram it sees rather than exactly one.
      {responder, ref} = spawn_monitor(fn -> natpmp_responder_loop(gateway) end)
      on_exit(fn -> Process.exit(responder, :kill) end)

      assert {:ok, 41_234, 7200} = NAT.NATPMP.map_port({127, 0, 0, 1}, :tcp, 6881, 7200)

      refute_received {:DOWN, ^ref, :process, ^responder, _}
    end
  end

  ## helpers -----------------------------------------------------------------

  # RFC 6886: the response opcode is the request opcode + 128, and it echoes the
  # internal port so a client can match it to its own request.
  defp natpmp_responder_loop(gateway) do
    case :gen_udp.recv(gateway, 0, 5_000) do
      {:ok, {ip, port, <<@natpmp_version, opcode, 0::16, internal::16, _ext::16, lifetime::32>>}} ->
        :ok =
          :gen_udp.send(
            gateway,
            ip,
            port,
            <<@natpmp_version, opcode + 128, 0::16, internal::16, 41_234::16, lifetime::32>>
          )

        natpmp_responder_loop(gateway)

      _ ->
        natpmp_responder_loop(gateway)
    end
  end

  # Acceptor caches the getifaddrs snapshot in :persistent_term (IpCache
  # refreshes it every 30 s); overriding it is how a test pins the host's
  # apparent addresses. This module is async: false, so no concurrent test can
  # observe the override.
  defp with_ip_snapshot(snapshot) do
    key = Acceptor.ip_cache_key()
    previous = :persistent_term.get(key, :none)

    on_exit(fn ->
      case previous do
        :none -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end)

    :persistent_term.put(key, snapshot)
  end
end

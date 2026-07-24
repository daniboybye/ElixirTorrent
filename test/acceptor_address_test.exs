defmodule AcceptorAddressTest do
  use ExUnit.Case, async: true

  test "all_global_ips includes cached multicast interfaces" do
    ips = Acceptor.all_global_ips()

    assert Map.has_key?(ips, :inet)
    assert Map.has_key?(ips, :inet6)
    assert Map.has_key?(ips, :inet6_all)
    assert Map.has_key?(ips, :multicast_interfaces)
    assert is_list(ips.inet6_all)
    assert is_list(ips.multicast_interfaces.inet)
    assert is_list(ips.multicast_interfaces.inet6)
  end

  test "format_ip renders IPv4 tuples" do
    assert Acceptor.format_ip({127, 0, 0, 1}) == "127.0.0.1"
  end

  test "announcable_ipv6 returns a list" do
    assert is_list(Acceptor.announcable_ipv6())
  end

  test "multicast interface snapshot keeps each active LAN interface" do
    ifaddrs = [
      {~c"en0",
       [
         flags: [:up, :running, :multicast],
         addr: {192, 168, 1, 10},
         addr: {0xFE80, 0, 0, 0, 0, 0, 0, 1}
       ]},
      {~c"en1",
       [
         flags: [:up, :running, :multicast],
         addr: {10, 0, 0, 8},
         addr: {0x2001, 0xDB8, 0, 1, 0, 0, 0, 2}
       ]},
      {~c"lo0",
       [
         flags: [:up, :running, :multicast, :loopback],
         addr: {127, 0, 0, 1},
         addr: {0, 0, 0, 0, 0, 0, 0, 1}
       ]}
    ]

    indexes = %{~c"en0" => 4, ~c"en1" => 9, ~c"lo0" => 1}
    index_fun = &{:ok, Map.fetch!(indexes, &1)}

    interfaces = Acceptor.multicast_interfaces_from(ifaddrs, index_fun)

    assert MapSet.new(interfaces.inet) == MapSet.new([{192, 168, 1, 10}, {10, 0, 0, 8}])
    assert MapSet.new(interfaces.inet6) == MapSet.new([4, 9])
  end
end

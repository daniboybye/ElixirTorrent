defmodule AcceptorAddressTest do
  use ExUnit.Case, async: true

  test "all_global_ips returns inet, inet6, and inet6_all keys" do
    ips = Acceptor.all_global_ips()

    assert Map.has_key?(ips, :inet)
    assert Map.has_key?(ips, :inet6)
    assert Map.has_key?(ips, :inet6_all)
    assert is_list(ips.inet6_all)
  end

  test "format_ip renders IPv4 tuples" do
    assert Acceptor.format_ip({127, 0, 0, 1}) == "127.0.0.1"
  end

  test "announcable_ipv6 returns a list" do
    assert is_list(Acceptor.announcable_ipv6())
  end
end

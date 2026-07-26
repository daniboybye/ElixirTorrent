defmodule AcceptorIpCacheTest do
  use ExUnit.Case, async: false

  test "all_global_ips falls back to compute when cache is empty" do
    key = Acceptor.ip_cache_key()
    prev = :persistent_term.get(key, :missing)

    on_exit(fn ->
      case prev do
        :missing -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end)

    :persistent_term.erase(key)

    direct = Acceptor.compute_all_global_ips()
    assert Acceptor.all_global_ips() == direct
  end

  test "IpCache refreshes the persistent_term snapshot" do
    key = Acceptor.ip_cache_key()
    prev = :persistent_term.get(key, :missing)
    pid = Process.whereis(Acceptor.IpCache)
    assert is_pid(pid)

    on_exit(fn ->
      case prev do
        :missing -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end)

    :persistent_term.erase(key)
    send(pid, :refresh)
    _ = :sys.get_state(pid)

    cached = :persistent_term.get(key)
    assert cached == Acceptor.compute_all_global_ips()
  end
end

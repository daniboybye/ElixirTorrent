defmodule DHT.ConfigTest do
  use ExUnit.Case, async: false

  alias DHT.Config

  @default_bootstrap [
    {"router.bittorrent.com", 6881},
    {"router.utorrent.com", 6881},
    {"dht.transmissionbt.com", 6881}
  ]

  setup do
    previous = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    Application.delete_env(:elixir_torrent, :dht)
    :ok
  end

  test "enabled? defaults to true on desktop hosts" do
    assert Config.enabled?() == true
  end

  test "enabled? reads Application env override" do
    Application.put_env(:elixir_torrent, :dht, enabled: false)
    refute Config.enabled?()

    Application.put_env(:elixir_torrent, :dht, enabled: true)
    assert Config.enabled?()
  end

  test "bootstrap_routers returns BEP 5 defaults" do
    assert Config.bootstrap_routers() == @default_bootstrap
  end

  test "bootstrap_routers reads Application env override" do
    custom = [{"dht.example.test", 9999}]
    Application.put_env(:elixir_torrent, :dht, bootstrap_routers: custom)
    assert Config.bootstrap_routers() == custom
  end

  test "lookup_timeout_ms defaults to 30_000 and accepts override" do
    assert Config.lookup_timeout_ms() == 30_000

    Application.put_env(:elixir_torrent, :dht, lookup_timeout_ms: 12_345)
    assert Config.lookup_timeout_ms() == 12_345
  end

  test "query_timeout_ms defaults to 5_000 and accepts override" do
    assert Config.query_timeout_ms() == 5_000

    Application.put_env(:elixir_torrent, :dht, query_timeout_ms: 1_500)
    assert Config.query_timeout_ms() == 1_500
  end

  test "max_lookup_peers defaults to 100 and accepts override" do
    assert Config.max_lookup_peers() == 100

    Application.put_env(:elixir_torrent, :dht, max_lookup_peers: 42)
    assert Config.max_lookup_peers() == 42
  end

  test "port defaults to nil and accepts override" do
    assert Config.port() == nil

    Application.put_env(:elixir_torrent, :dht, port: 7777)
    assert Config.port() == 7777
  end

  test "version_string pads the engine version prefix to four bytes" do
    prefix = String.slice(ElixirTorrent.version(), 0, 4)
    assert Config.version_string() == String.pad_trailing(prefix, 4, "0")
    assert byte_size(Config.version_string()) == 4
  end
end

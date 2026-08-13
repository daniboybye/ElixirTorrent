defmodule DHT.Config do
  @moduledoc """
  BEP 5 DHT runtime configuration (`Application` env under `:elixir_torrent, :dht`).

  Defaults: enabled on desktop, UDP port 6881 (falls back through Acceptor range),
  bootstrap routers from BEP 5, lookup timeout 30s.
  """

  @bootstrap_routers [
    {"router.bittorrent.com", 6881},
    {"router.utorrent.com", 6881},
    {"dht.transmissionbt.com", 6881}
  ]

  @lookup_timeout_ms 30_000
  @query_timeout_ms 5_000
  @max_lookup_peers 100

  @doc "Whether DHT is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:elixir_torrent, :dht, [])
    |> Keyword.get(:enabled, default_enabled?())
  end

  @doc "Bootstrap router host/port pairs (BEP 5 § bootstrap)."
  @spec bootstrap_routers() :: [{String.t(), :inet.port_number()}]
  def bootstrap_routers do
    Application.get_env(:elixir_torrent, :dht, [])
    |> Keyword.get(:bootstrap_routers, @bootstrap_routers)
  end

  @doc """
  Whether the routing table is loaded from and saved to `DHT.RoutingStore`.

  Off in `:test`: the persisted table holds real internet nodes, and the boot
  bootstrap lookup would start querying them immediately. Disabling the save
  side too keeps a test run from overwriting a developer's warm table with the
  empty one the suite runs on.
  """
  @spec routing_store?() :: boolean()
  def routing_store? do
    Application.get_env(:elixir_torrent, :dht, [])
    |> Keyword.get(:routing_store, true)
  end

  @doc "Overall get_peers lookup timeout in milliseconds."
  @spec lookup_timeout_ms() :: pos_integer()
  def lookup_timeout_ms do
    Application.get_env(:elixir_torrent, :dht, [])
    |> Keyword.get(:lookup_timeout_ms, @lookup_timeout_ms)
  end

  @doc "Per-query UDP timeout in milliseconds."
  @spec query_timeout_ms() :: pos_integer()
  def query_timeout_ms do
    Application.get_env(:elixir_torrent, :dht, [])
    |> Keyword.get(:query_timeout_ms, @query_timeout_ms)
  end

  @doc "Maximum peers returned from a DHT lookup."
  @spec max_lookup_peers() :: pos_integer()
  def max_lookup_peers do
    Application.get_env(:elixir_torrent, :dht, [])
    |> Keyword.get(:max_lookup_peers, @max_lookup_peers)
  end

  @doc "Preferred UDP listen port; `nil` lets the server pick from Acceptor range."
  @spec port() :: :inet.port_number() | nil
  def port do
    Application.get_env(:elixir_torrent, :dht, [])
    |> Keyword.get(:port)
  end

  @doc "BEP 20 client version string for KRPC `v` key."
  @spec version_string() :: binary()
  def version_string do
    prefix = String.slice(ElixirTorrent.version(), 0, 4)
    String.pad_trailing(prefix, 4, "0")
  end

  @spec default_enabled?() :: boolean()
  defp default_enabled? do
    case :os.type() do
      {:unix, :darwin} -> true
      {:unix, _} -> true
      {:win32, _} -> true
      _ -> true
    end
  end
end

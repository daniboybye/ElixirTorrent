defmodule ElixirTorrentApplication do
  use Application

  # Named hackney pool for HTTP tracker announces + BEP 48 scrapes. Sharing a
  # keep-alive pool lets successive announces to the same tracker (min_interval
  # 15 min, scrape tick 5 min) skip the TCP + TLS handshake round-trips.
  # Pool key includes `connect_options`, so the IPv4-bound-source announce and
  # the default-route IPv6 announce automatically get separate slots per tracker.
  @tracker_pool :elixir_torrent_tracker
  @tracker_pool_idle_ms 5 * 60 * 1_000

  @doc false
  @spec tracker_pool() :: atom()
  def tracker_pool, do: @tracker_pool

  def start(_type, _args) do
    :ok = start_tracker_pool()

    [
      {Registry, keys: :unique, name: Registry},
      Peer.Endpoints,
      Peer.DialBackoff,
      Peer.UtPex.RecentCache,
      Peer.DialStats,
      Peer.Holepunch.Store,
      Torrents,
      PeerDiscovery,
      Acceptor,
      DHT,
      UTP.Dispatcher,
      NAT.PortMapper,
      Magnet.Fetcher.Supervisor,
      Magnet.Fetcher.ConnectionLimit,
      Magnet.Bootstrap.Supervisor
    ]
    |> Supervisor.start_link(strategy: :one_for_one)
  end

  defp start_tracker_pool do
    case :hackney_pool.start_pool(@tracker_pool,
           max_connections: 30,
           timeout: @tracker_pool_idle_ms
         ) do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end

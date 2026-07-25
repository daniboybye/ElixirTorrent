defmodule ElixirTorrentApplication do
  use Application

  def start(_type, _args) do
    :ok = Peer.initialize_id()

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
end

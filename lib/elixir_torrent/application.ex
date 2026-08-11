defmodule ElixirTorrentApplication do
  @moduledoc false
  use Application

  @spec start(atom(), term()) :: Supervisor.on_start()
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

defmodule ElixirTorrentApplication do
  use Application

  def start(_type, _args) do
    [
      {Registry, keys: :unique, name: Registry},
      Peer.Holepunch.Store,
      Torrents,
      PeerDiscovery,
      Acceptor,
      Magnet.Fetcher.Supervisor,
      Magnet.Fetcher.ConnectionLimit,
      Magnet.Bootstrap.Supervisor
    ]
    |> Supervisor.start_link(strategy: :one_for_all)
  end
end

defmodule Bittorrent.Application do
  use Application

  def start(_type, _args) do
    [
      {Registry, keys: :unique, name: Registry},
      Bittorrent.Torrents, 
      Bittorrent.Acceptor,
      Bittorrent.PeerDiscovery
    ]
    |> Supervisor.start_link([strategy: :one_for_all, name: Bittorrent])
  end
end

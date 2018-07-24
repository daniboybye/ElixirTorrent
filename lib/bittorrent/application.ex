defmodule Bittorrent.Application do
  use Application

  def start(_type, _args) do
    [
      {Registry, keys: :unique, name: RegistryProcesses},
      {
        DynamicSupervisor, 
        strategy: :one_for_one, 
        name: Bittorent.Torrents, 
        max_restarts: 0
      },
      Bittorent.Acceptor,
      Bittorrent.RegistryTorrents,
      Bittorrent.PeerDiscovery
    ]
    |> Supervisor.start_link([strategy: :one_for_all, name: Bittorrent])
  end
end

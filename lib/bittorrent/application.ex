defmodule Bittorrent.Application do
  use Application

  def start(_type, _args) do
    [
      {Registry, keys: :unique, name: Registry},
      Torrents,
      PeerDiscovery,
      Acceptor
    ]
    |> Supervisor.start_link(strategy: :one_for_all)
  end
end

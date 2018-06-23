defmodule Bittorrent.Application do
  use Application

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Bittorent.Torrents, max_restarts: 0},
      Bittorent.Acceptor,
      Bittorrent.Registry,
      Bittorrent.PeerDiscovery
    ]

    opts = [strategy: :one_for_all, name: Bittorrent]

    Supervisor.start_link(children, opts)
  end
end

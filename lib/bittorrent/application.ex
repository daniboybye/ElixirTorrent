defmodule Bittorrent.Application do
  use Application

  @port 6881
  @peer_id "-DANIBOYBYE_ELIXIR3-"

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Bittorent.Torrents},
      {Bittorent.Acceptor.Supervisor, {@port,@peer_id}},
      {Bittorrent.Registry, @peer_id},
      {Bittorrent.PeerDiscovery, {@port,@peer_id}}
    ]

    opts = [strategy: :one_for_all, name: Bittorrent]

    Supervisor.start_link(children, opts)
  end
end

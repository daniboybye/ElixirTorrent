defmodule ElixirTorrent do
  use Application

  def version, do: "ET0-1-0"

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

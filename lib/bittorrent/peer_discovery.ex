defmodule Bittorrent.PeerDiscovery do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init(args) do
    [
      {Task.Supervisor, name: __MODULE__.Requests, strategy: :one_for_one},
      {__MODULE__.Controller, args}
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end

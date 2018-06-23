defmodule Bittorrent.PeerDiscovery do
  use Supervisor

  @port 6881
  @peer_id "-DANIBOYBYE_ELIXIR3-"

  def port(), do: @port
  
  def peer_id(), do: @peer_id

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init(args) do
    [
      {Task.Supervisor, name: __MODULE__.Requests, strategy: :one_for_one},
      __MODULE__.Controller
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end

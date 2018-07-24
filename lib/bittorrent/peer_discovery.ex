defmodule Bittorrent.PeerDiscovery do
  use Supervisor, type: :supervisor

  def port(), do: 6881
  
  def peer_id(), do: "-DANIBOYBYE_ELIXIR3-"

  def start_link() do
    Supervisor.start_link(__MODULE__, nil)
  end

  def init(_) do
    [
      {
        Task.Supervisor, 
        name: __MODULE__.Requests,
        strategy: :one_for_one, 
        max_restarts: 0
      },
      __MODULE__.Controller
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end

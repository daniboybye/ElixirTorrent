defmodule Bittorrent.PeerDiscovery do
  use Supervisor, type: :supervisor

  def start_link(), do: Supervisor.start_link(__MODULE__, nil)
  
  def port(), do: 6881
  
  def peer_id(), do: "-DANIBOYBYE_ELIXIR3-"

  defdelegate has_hash?(hash), to: __MODULE__.Controller

  defdelegate first_request(file_name), to: __MODULE__.Controller

  defdelegate get(key), to: __MODULE__.Controller

  defdelegate put(pair), to: __MODULE__.Controller

  defdelegate delete(key), to: __MODULE__.Controller

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

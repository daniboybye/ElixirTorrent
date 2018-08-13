defmodule PeerDiscovery do
  use Supervisor, type: :supervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

  @spec peer_id() :: Peer.peer_id()
  def peer_id(), do: "-DANIBOYBYE_ELIXIR3-"

  defdelegate has_hash?(hash), to: __MODULE__.Controller

  defdelegate request(torrent), to: __MODULE__.Controller

  defdelegate get(key), to: __MODULE__.Controller

  def init(_) do
    [
      {
        Task.Supervisor,
        name: __MODULE__.Requests, strategy: :one_for_one, max_restarts: 0
      },
      __MODULE__.Controller
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end

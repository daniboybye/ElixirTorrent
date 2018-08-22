defmodule PeerDiscovery do
  use Supervisor, type: :supervisor, start: {__MODULE__, :start_link, []}

  @spec start_link() :: Supervisor.on_start()
  def start_link(), do: Supervisor.start_link(__MODULE__, nil)

  @spec peer_id() :: Peer.peer_id()
  def peer_id(), do: "E0-1-0-DANIBOYBYE356"

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

defmodule PeerDiscovery do
  use Supervisor, type: :supervisor, start: {__MODULE__, :start_link, []}

  alias __MODULE__.{Controller, ConnectionIds}

  @spec start_link() :: Supervisor.on_start()
  def start_link(), do: Supervisor.start_link(__MODULE__, nil)

  defdelegate put(torrent, list), to: Controller

  defdelegate get(key), to: Controller

  defdelegate connection_id(announce, socket, ip, port), to: ConnectionIds, as: :get

  def init(_) do
    [
      {
        Task.Supervisor,
        name: __MODULE__.Requests, strategy: :one_for_one, max_restarts: 0
      },
      ConnectionIds,
      Controller
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end

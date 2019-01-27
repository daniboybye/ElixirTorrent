defmodule PeerDiscovery do
  alias __MODULE__.{Announce, AnnouncesSupervisor, ConnectionIds}

  def child_spec(_) do
    children = [
      {
        Task.Supervisor,
        name: __MODULE__.Requests, strategy: :one_for_one, max_restarts: 0
      },
      {
        DynamicSupervisor,
        name: __MODULE__.AnnouncesSupervisor, strategy: :one_for_one, max_restarts: 0
      },
      ConnectionIds
    ]

    opts = [strategy: :one_for_all]

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, opts]}
    }
  end

  def register(pid, torrent) do
    DynamicSupervisor.start_child(
      AnnouncesSupervisor,
      {Announce, [pid, torrent]}
    )
  end

  defdelegate get(hash), to: Announce

  defdelegate connecting_to_peers(hash), to: Announce

  defdelegate connection_id(socket, ip, port), to: ConnectionIds, as: :get
end

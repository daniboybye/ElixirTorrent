defmodule Torrents do
  use DynamicSupervisor, type: :supervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_) do
    DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  defdelegate download(file_name), to: PeerDiscovery, as: :first_request

  @spec start_torrent(Torrent.Struct.t()) :: DynamicSupervisor.on_start_child()
  def start_torrent(torrent) do
    DynamicSupervisor.start_child(__MODULE__, {Torrent, torrent})
  end

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 0)
  end
end

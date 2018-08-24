defmodule Torrent.Uploader do
  use DynamicSupervisor, type: :supervisor

  require Via
  Via.make()

  @spec start_link(Torrent.t()) :: Supervisor.on_start()
  def start_link(%Torrent{hash: hash}) do
    DynamicSupervisor.start_link(__MODULE__, nil, name: via(hash))
  end

  @spec request(
          Torrent.hash(),
          Peer.peer_id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length()
        ) :: DynamicSupervisor.on_start_child()
  def request(hash, peer_id, index, begin, length) do
    DynamicSupervisor.start_child(
      via(hash),
      {__MODULE__.Task, {hash, peer_id, index, begin, length}}
    )
  end

  defdelegate cancel(hash, peer_id, index, begin, length), to: __MODULE__.Task

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 0)
  end
end

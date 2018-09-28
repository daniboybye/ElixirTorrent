defmodule Torrent.Downloads do
  use DynamicSupervisor, restart: :transient, type: :supervisor

  alias __MODULE__.Piece

  require Via

  Via.make()

  @spec start_link(Torrent.t()) :: Supervisor.on_start()
  def start_link(%Torrent{hash: hash}) do
    DynamicSupervisor.start_link(__MODULE__, nil, name: via(hash))
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash), do: DynamicSupervisor.stop(via(hash))

  @spec piece(Torrent.hash(), Torrent.index(), Torrent.length(), Piece.mode()) :: :ok
  def piece(hash, index, length, mode) do
    
    DynamicSupervisor.start_child(
      via(hash),
      {Piece, [index: index, hash: hash, length: length]}
    )

    Piece.download(hash, index, mode)
  end

  defdelegate request(hash, index, peer_id), to: Piece

  defdelegate response(hash, index, peer_id, begin, block), to: Piece

  defdelegate reject(hash, index, peer_id, begin, length), to: Piece

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1_000)
  end
end

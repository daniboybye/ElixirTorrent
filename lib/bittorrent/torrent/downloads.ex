defmodule Torrent.Downloads do
  use DynamicSupervisor, restart: :transient, type: :supervisor

  require Via
  require Logger

  Via.make()

  @spec start_link(Torrent.t()) :: Supervisor.on_start()
  def start_link(%Torrent{hash: hash}) do
    DynamicSupervisor.start_link(__MODULE__, nil, name: via(hash))
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash), do: DynamicSupervisor.stop(via(hash))

  @spec piece(Torrent.hash(), Torrent.index(), Torrent.length(), __MODULE__.Piece.mode()) :: :ok
  def piece(hash, index, length, mode) do
    # Logger.info("current piece download #{index}")
    DynamicSupervisor.start_child(
      via(hash),
      {__MODULE__.Piece, {index, hash, length}}
    )

    __MODULE__.Piece.download(hash, index, mode)
  end

  defdelegate want_request(hash, index, peer_id), to: __MODULE__.Piece

  defdelegate request_response(hash, index, peer_id, begin, block), to: __MODULE__.Piece

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1_000)
  end
end

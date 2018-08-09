defmodule Torrent.Downloads do
  use DynamicSupervisor, restart: :transient, type: :supervisor

  require Via
  require Logger

  Via.make()

  @spec start_link(Torrent.Struct.t()) :: Supervisor.on_start()
  def start_link(%Torrent.Struct{hash: hash}) do
    DynamicSupervisor.start_link(__MODULE__, nil, name: via(hash))
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash), do: DynamicSupervisor.stop(via(hash))

  @spec piece(Torrent.hash(), Torrent.index(), Torrent.length()) :: :ok
  def piece(hash, index, length) do
    Logger.info("current piece download #{index}")

    # unless __MODULE__.Piece.run?(hash, index) do
    DynamicSupervisor.start_child(
      via(hash),
      {__MODULE__.Piece, {index, hash, length}}
    )

    # end

    __MODULE__.Piece.download(hash, index)
  end

  defdelegate want_request(hash, index, peer_id), to: __MODULE__.Piece

  defdelegate request_response(hash, index, peer_id, begin, block), to: __MODULE__.Piece

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1_000)
  end
end

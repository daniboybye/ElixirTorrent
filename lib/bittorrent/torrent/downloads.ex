defmodule Torrent.Downloads do
  use DynamicSupervisor, restart: :transient, type: :supervisor
  use Via

  alias __MODULE__.Piece

  @spec start_link(Torrent.t()) :: Supervisor.on_start()
  def start_link(%Torrent{hash: hash}) do
    DynamicSupervisor.start_link(__MODULE__, nil, name: via(hash))
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash), do: DynamicSupervisor.stop(via(hash))

  #@spec piece(Torrent.hash(), Torrent.index(), Torrent.length(), Piece.mode()) :: :ok
  def piece(hash, index, length, downloaded, requests_are_dealt, mode \\ nil) do
    DynamicSupervisor.start_child(
      via(hash),
      {Piece, [index: index, hash: hash, length: length, downloaded: downloaded, requests_are_dealt: requests_are_dealt]}
    ) |> case do
    {:ok, pid} ->
      pid
    {:ok, pid, _} ->
      pid
    {:error, {:already_started, pid}} ->
      pid
    end
    |> Piece.download(mode)
  end

  defdelegate piece_max_length, to: Piece, as: :max_length

  defdelegate request(hash, index, peer_id, callback), to: Piece

  defdelegate response(hash, index, peer_id, begin, block), to: Piece

  defdelegate reject(hash, index, peer_id, begin, length), to: Piece

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1_000)
  end
end

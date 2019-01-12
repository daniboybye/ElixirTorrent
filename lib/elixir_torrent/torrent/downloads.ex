defmodule Torrent.Downloads do
  use Via

  alias __MODULE__.Piece

  def child_spec(hash) do
    %{
      id: __MODULE__,
      restart: :transient,
      type: :supervisor,
      start:
        {DynamicSupervisor, :start_link,
         [[name: via(hash), extra_arguments: [hash], strategy: :one_for_one, max_restarts: 100]]}
    }
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash), do: DynamicSupervisor.stop(via(hash))

  @spec piece(Torrent.hash(), Torrent.index(), (() -> :ok), (() -> :ok)) :: :ok
  def piece(hash, index, downloaded, requests_are_dealt) do
    case DynamicSupervisor.start_child(via(hash), {Piece, [index]}) do
      {:ok, pid} ->
        pid

      {:ok, pid, _} ->
        pid

      {:error, {:already_started, pid}} ->
        pid
    end
    |> Piece.download(downloaded, requests_are_dealt)
  end

  defdelegate piece_max_length, to: Piece, as: :max_length

  defdelegate request(hash, index, peer_id, callback), to: Piece

  defdelegate response(hash, index, peer_id, begin, block), to: Piece

  defdelegate reject(hash, index, peer_id, begin, length), to: Piece
end

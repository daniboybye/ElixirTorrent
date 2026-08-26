defmodule Torrent.Downloads do
  @moduledoc """
  DynamicSupervisor of per-piece download workers for one torrent hash.
  """

  use Via

  alias __MODULE__.Piece

  @spec child_spec(Torrent.hash()) :: Supervisor.child_spec()
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
  def stop(hash) do
    DynamicSupervisor.stop(via(hash))
  catch
    :exit, _ -> :ok
  end

  @spec piece(Torrent.hash(), Torrent.index(), Piece.callback(), Piece.callback()) :: :ok
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

  # Whether the piece worker for {hash, index} is alive AND still has
  # unclaimed subpieces to hand out. Returns false for dead workers or those
  # whose waiting list is drained (all subpieces handed to some peer). Used
  # by Swarm.assign_peer_to_piece? so a peer pinned to a drained piece can
  # be re-pinned to a fresh active piece.
  defdelegate piece_has_waiting?(hash, index), to: Piece, as: :has_waiting?

  # Blocks nobody has claimed yet. `piece_has_waiting?/2` also counts blocks
  # in flight to other peers, which is right for endgame but wrong when
  # deciding whether *this* peer still has work here.
  defdelegate piece_has_unclaimed?(hash, index), to: Piece, as: :has_unclaimed?

  # Whether a piece still has anything for one specific peer: unclaimed blocks,
  # or blocks that peer is already fetching.
  defdelegate piece_serves_peer?(hash, index, peer_id), to: Piece, as: :serves_peer?

  # Upgrade a running worker to endgame; see `Piece.enter_endgame/2`.
  defdelegate piece_enter_endgame(hash, index), to: Piece, as: :enter_endgame

  # Distinguishes "no worker yet" from "worker with nothing left to hand out",
  # which `piece_has_waiting?/2` collapses into `false`.
  @spec piece_whereis(Torrent.hash(), Torrent.index()) :: pid() | nil
  defdelegate piece_whereis(hash, index), to: Piece, as: :whereis

  @spec piece_has_in_flight?(Torrent.hash(), Torrent.index()) :: boolean()
  def piece_has_in_flight?(hash, index) do
    case Piece.whereis(hash, index) do
      nil ->
        false

      pid ->
        GenServer.call(pid, :has_in_flight?, 1_000)
    end
  catch
    :exit, _ -> false
  end

  @spec abort_idle_piece(Torrent.hash(), Torrent.index(), keyword()) :: :ok
  def abort_idle_piece(hash, index, opts \\ []), do: Piece.abort_if_orphan(hash, index, opts)

  @spec active_indices(Torrent.hash()) :: [Torrent.index()]
  def active_indices(hash) do
    case GenServer.whereis(via(hash)) do
      nil ->
        []

      _ ->
        via(hash)
        |> DynamicSupervisor.which_children()
        |> Enum.flat_map(&active_piece_index(&1, hash))
    end
  end

  @spec piece_active?(Torrent.hash(), Torrent.index()) :: boolean()
  def piece_active?(hash, index), do: index in active_indices(hash)

  defp active_piece_index({_id, pid, _, _}, hash) when is_pid(pid) do
    case Registry.keys(Registry, pid) do
      [{{index, ^hash}, Piece}] when is_integer(index) -> [index]
      _ -> []
    end
  end

  defp active_piece_index(_, _hash), do: []
end

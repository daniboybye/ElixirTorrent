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

  @doc """
  Hand `peer_id` one block from ANY active piece `eligible?` accepts.

  A peer works down one pinned piece, and a piece is small (1 MiB = 64 blocks): a
  fast peer drains it in well under a second. If the next piece is only chosen by
  an outside signal (a new piece starting, the 2 s reconcile tick) the peer's
  request queue falls to zero at every piece boundary and the TCP/uTP pipe sits
  empty until that signal arrives. A request pipeline only helps while it stays
  full across boundaries, so the peer must be able to continue on the next piece
  in the same step, from the blocks nobody has claimed yet. libtorrent's picker
  does the same: one pick spans pieces up to the peer's desired queue size.

  `eligible?` is evaluated first and locally (no process call): it is where the
  caller applies what only it knows about the peer (has the piece, not choked for
  it, not a corrupt source, not the piece that just drained). Candidates are tried
  in ascending index order so peers converge on the same piece and finish it
  rather than leaving many half-done; each candidate costs one bounded in-memory
  `Piece.request/4`, and a piece with nothing to give (`:noop`) or a dead worker
  (`:error`) just moves on to the next.

  Returns `{:ok, index}` for the piece that accepted (its worker will invoke
  `callback` with the block) or `:none`. It only ever looks at pieces that are
  already active, so it can never start a piece and the parallel-piece cap is
  untouched; the request window is the caller's to enforce before calling.
  """
  @spec request_any(
          Torrent.hash(),
          Peer.id(),
          (Torrent.index() -> boolean()),
          Piece.callback_peer_request()
        ) :: {:ok, Torrent.index()} | :none
  def request_any(hash, peer_id, eligible?, callback) when is_function(eligible?, 1) do
    hash
    |> active_indices()
    |> Enum.sort()
    |> Enum.filter(eligible?)
    |> Enum.find_value(:none, fn index ->
      case Piece.request(hash, index, peer_id, callback) do
        :ok -> {:ok, index}
        _noop_or_dead -> nil
      end
    end)
  end

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

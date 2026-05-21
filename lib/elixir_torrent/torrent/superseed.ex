defmodule Torrent.Superseed do
  @moduledoc """
  BEP 16 super-seeding mode: one-piece-at-a-time upload hints to a single leecher.
  """

  use GenServer
  use Via

  alias Torrent.{Bitfield, PiecesStatistic}

  @type phase :: :inactive | :armed | :active | :finished
  @type assignment :: Torrent.index() | nil

  @spec start_link(Torrent.hash()) :: GenServer.on_start()
  def start_link(hash), do: GenServer.start_link(__MODULE__, hash, name: via(hash))

  @spec active?(Torrent.hash()) :: boolean()
  def active?(hash), do: safe_call(hash, :active?, false)

  @spec arm(Torrent.hash()) :: :armed | :inactive
  def arm(hash), do: safe_call(hash, :arm, :inactive)

  @spec activate(Torrent.hash(), non_neg_integer()) :: :active | :inactive
  def activate(hash, confirmed_seed_count),
    do: safe_call(hash, {:activate, confirmed_seed_count}, :inactive)

  @spec assign(Torrent.hash(), Peer.id(), Torrent.bitfield() | :all | :none | nil) ::
          {:ok, Torrent.index()} | :none | :inactive
  def assign(hash, peer_id, bitfield),
    do: safe_call(hash, {:assign, peer_id, bitfield}, :inactive)

  @spec peer_have(Torrent.hash(), Peer.id(), Torrent.index()) ::
          {:rotate, Peer.id(), assignment()} | :ok
  def peer_have(hash, peer_id, index),
    do: safe_call(hash, {:peer_have, peer_id, index}, :ok)

  @spec confirm_seed(Torrent.hash(), Peer.id()) :: :active | :deactivated | :inactive
  def confirm_seed(hash, peer_id),
    do: safe_call(hash, {:confirm_seed, peer_id}, :inactive)

  @spec release(Torrent.hash(), Peer.id()) :: :ok
  def release(hash, peer_id) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:release, peer_id})
    end
  rescue
    # Peer.Controller.terminate/2 may finish after the application Registry has
    # stopped. Cleanup is best-effort because the Superseed process is gone too.
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec pick_piece(
          [{Torrent.index(), non_neg_integer()}],
          MapSet.t(Torrent.index()),
          MapSet.t(Torrent.index()),
          MapSet.t(Torrent.index())
        ) :: assignment()
  def pick_piece(availabilities, peer_has, assigned, advertised) do
    candidates =
      Enum.reject(availabilities, fn {index, _availability} ->
        MapSet.member?(peer_has, index) or MapSet.member?(assigned, index)
      end)

    fresh = Enum.reject(candidates, fn {index, _} -> MapSet.member?(advertised, index) end)

    case if(fresh == [], do: candidates, else: fresh) do
      [] ->
        nil

      choices ->
        choices
        |> Enum.min_by(fn {index, availability} -> {availability, index} end)
        |> elem(0)
    end
  end

  @impl GenServer
  def init(hash) do
    # A restored complete torrent deliberately falls back to ordinary seeding.
    # Peer assignments belong to dead connections and cannot be resumed safely;
    # marking the phase finished also prevents the restored session from being
    # mistaken for a newly completed initial seed.
    phase = if Torrent.get(hash, :peer_status) == :seed, do: :finished, else: :inactive

    {:ok,
     %{
       hash: hash,
       phase: phase,
       assignments: %{},
       peer_pieces: %{},
       advertised: MapSet.new(),
       confirmed_seeds: MapSet.new()
     }}
  end

  @impl GenServer
  def handle_call(:active?, _from, state), do: {:reply, state.phase == :active, state}

  def handle_call(:arm, _from, %{phase: :inactive} = state) do
    {:reply, :armed, %{state | phase: :armed}}
  end

  def handle_call(:arm, _from, state), do: {:reply, :inactive, state}

  def handle_call({:activate, 0}, _from, %{phase: :armed} = state) do
    {:reply, :active, %{state | phase: :active}}
  end

  def handle_call({:activate, _seed_count}, _from, %{phase: :armed} = state) do
    {:reply, :inactive, %{state | phase: :finished}}
  end

  def handle_call({:activate, _seed_count}, _from, state) do
    reply = if state.phase == :active, do: :active, else: :inactive
    {:reply, reply, state}
  end

  def handle_call({:assign, peer_id, bitfield}, _from, %{phase: :active} = state) do
    peer_pieces = pieces_from_bitfield(bitfield, pieces_count(state.hash))
    state = put_in(state.peer_pieces[peer_id], peer_pieces)

    case Map.fetch(state.assignments, peer_id) do
      {:ok, index} ->
        {:reply, {:ok, index}, state}

      :error ->
        {reply, state} = assign_peer(state, peer_id)
        {:reply, reply, state}
    end
  end

  def handle_call({:assign, _peer_id, _bitfield}, _from, state),
    do: {:reply, :inactive, state}

  def handle_call({:peer_have, peer_id, index}, _from, %{phase: :active} = state) do
    peer_pieces = Map.get(state.peer_pieces, peer_id, MapSet.new()) |> MapSet.put(index)
    state = put_in(state.peer_pieces[peer_id], peer_pieces)

    case find_assignment_for_piece(state.assignments, index) do
      nil ->
        {:reply, :ok, state}

      assigned_peer ->
        rotate_assignment_after_have(state, assigned_peer, index)
    end
  end

  def handle_call({:peer_have, _peer_id, _index}, _from, state), do: {:reply, :ok, state}

  def handle_call({:confirm_seed, peer_id}, _from, %{phase: :active} = state) do
    confirmed = MapSet.put(state.confirmed_seeds, peer_id)

    # One complete remote seed means the initial seed has produced the second
    # full swarm copy; hiding pieces beyond this point only restricts throughput.
    state = %{
      state
      | phase: :finished,
        assignments: %{},
        confirmed_seeds: confirmed
    }

    {:reply, :deactivated, state}
  end

  def handle_call({:confirm_seed, _peer_id}, _from, state), do: {:reply, :inactive, state}

  @impl GenServer
  def handle_cast({:release, peer_id}, state) do
    {:noreply,
     state
     |> update_in([:assignments], &Map.delete(&1, peer_id))
     |> update_in([:peer_pieces], &Map.delete(&1, peer_id))
     |> update_in([:confirmed_seeds], &MapSet.delete(&1, peer_id))}
  end

  defp assign_peer(state, peer_id) do
    assigned =
      state.assignments
      |> Map.values()
      |> MapSet.new()

    peer_has = Map.get(state.peer_pieces, peer_id, MapSet.new())
    index = pick_piece(availabilities(state.hash), peer_has, assigned, state.advertised)

    case index do
      nil ->
        {:none, state}

      piece ->
        state = %{
          state
          | assignments: Map.put(state.assignments, peer_id, piece),
            advertised: MapSet.put(state.advertised, piece)
        }

        {{:ok, piece}, state}
    end
  end

  defp find_assignment_for_piece(assignments, index) do
    case Enum.find(assignments, fn {_assigned_peer, piece} -> piece == index end) do
      {assigned_peer, ^index} -> assigned_peer
      _ -> nil
    end
  end

  defp rotate_assignment_after_have(state, assigned_peer, _index) do
    state = update_in(state.assignments, &Map.delete(&1, assigned_peer))
    {reply, state} = assign_peer(state, assigned_peer)

    new_piece =
      case reply do
        {:ok, piece} -> piece
        :none -> nil
      end

    {:reply, {:rotate, assigned_peer, new_piece}, state}
  end

  defp availabilities(hash) do
    count = pieces_count(hash)
    Enum.map(0..(count - 1), &{&1, PiecesStatistic.availability(hash, &1)})
  end

  defp pieces_count(hash), do: Torrent.get(hash, :pieces_count)

  defp pieces_from_bitfield(:all, count), do: MapSet.new(0..(count - 1))

  defp pieces_from_bitfield(bitfield, count) when is_binary(bitfield) do
    0..(count - 1)
    |> Enum.filter(&Bitfield.have?(bitfield, &1))
    |> MapSet.new()
  end

  defp pieces_from_bitfield(_, _count), do: MapSet.new()

  defp safe_call(hash, message, fallback) do
    case GenServer.whereis(via(hash)) do
      nil -> fallback
      _pid -> GenServer.call(via(hash), message)
    end
  catch
    :exit, _ -> fallback
  end
end

defmodule Torrent.Swarm do
  use Via

  alias Torrent.{Downloads, Model}

  require Logger

  def child_spec(hash) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {
        DynamicSupervisor,
        :start_link,
        [
          [
            name: via(hash),
            extra_arguments: [hash],
            strategy: :one_for_one,
            max_restarts: 0
          ]
        ]
      }
    }
  end

  @spec interested(Torrent.hash(), Torrent.index()) :: :ok
  def interested(hash, index), do: interested_for_piece(hash, index)

  @spec interested_for_piece(Torrent.hash(), Torrent.index()) :: :ok
  def interested_for_piece(hash, index) do
    hash
    |> interest_peer_pids(index)
    |> Enum.each(fn pid ->
      case Peer.get_key(pid) do
        key when is_tuple(key) -> Peer.Controller.interested_sync(key, index)
        _ -> :ok
      end
    end)
  end

  @doc false
  @spec assign_peer_to_piece?(Torrent.hash(), Peer.key(), Torrent.index(), [Torrent.index()]) ::
          boolean()
  def assign_peer_to_piece?(hash, key, index, active_indices) when is_list(active_indices) do
    do_assign_peer_to_piece?(hash, key, index, active_indices)
  end

  def assign_peer_to_piece?(hash, key, index) do
    do_assign_peer_to_piece?(hash, key, index, Downloads.active_indices(hash))
  end

  @doc false
  @spec interest_peer_pids(Torrent.hash(), Torrent.index()) :: [pid()]
  def interest_peer_pids(hash, index) do
    active = Downloads.active_indices(hash)

    hash
    |> peer_pids()
    |> sort_peers_seeders_first()
    |> Enum.flat_map(fn pid ->
      case Peer.get_key(pid) do
        key when is_tuple(key) ->
          if do_assign_peer_to_piece?(hash, key, index, active), do: [pid], else: []

        _ ->
          []
      end
    end)
  end

  @doc false
  @spec sort_peers_seeders_first([pid()]) :: [pid()]
  def sort_peers_seeders_first(pids) do
    # Seeders (bitfield :all) have every piece and usually higher upload; under
    # scarce unchokes, pin them first so their request pipeline fills before
    # fellow leechers race for the same blocks.
    Enum.sort_by(pids, &peer_seeder_rank/1)
  end

  # Decide whether to (re)pin a peer to the new `index`. Peer must have the
  # bitfield bit set. Then:
  #   * no current pin → assign
  #   * already pinned to this index → keep
  #   * pinned to another piece that is no longer active → free to move
  #   * pinned to another piece that IS still active BUT has no unclaimed
  #     subpieces left (drained) → free to move. This is the fix: without
  #     it, a peer would sit pinned to a drained piece until its worker
  #     died, losing all its bandwidth to the pump.
  #   * pinned to another active piece with waiting subpieces BUT this peer
  #     is choked and has delivered zero bytes on the pin for longer than
  #     @stale_pin_ms → free to move (endgame monopoly fix). In endgame, a
  #     stable hash spreads useless pins across ALL remaining indices so one
  #     choked piece does not hoard the whole swarm.
  #   * otherwise: keep the current pin (they're presumably still working).
  defp do_assign_peer_to_piece?(hash, key, index, active_indices) do
    Peer.Controller.has_index?(key, index) and
      case Peer.Controller.download_piece(key) do
        nil ->
          true

        ^index ->
          true

        other ->
          may_leave_pin?(hash, key, index, other, active_indices)
      end
  catch
    :exit, _ -> false
  end

  defp may_leave_pin?(hash, key, index, other, active_indices) do
    drained? = not Downloads.piece_has_waiting?(hash, other)
    endgame? = Model.get(hash, :mode) == :endgame
    useless? = useless_pin_may_switch?(hash, key, index, other, active_indices)

    cond do
      other not in active_indices ->
        true

      drained? and not endgame? ->
        true

      drained? and endgame? and useless? ->
        true

      useless? ->
        true

      true ->
        false
    end
  end

  # A peer choked with zero bytes on its current pin for long enough is not
  # contributing to that piece. In endgame, only re-pin to another active
  # index when a stable hash says this peer "owns" that index — otherwise
  # reconcile's multi-interest pass would leave every peer on the last index.
  defp useless_pin_may_switch?(hash, key, index, _other, active_indices) do
    Peer.Controller.stale_useless_pin?(key) and
      case Model.get(hash, :mode) do
        :endgame when length(active_indices) > 1 ->
          endgame_preferred_index(key, active_indices) == index

        _ ->
          true
      end
  end

  defp endgame_preferred_index({_hash, peer_id}, active_indices) do
    sorted = Enum.sort(active_indices)
    bucket = rem(:erlang.phash2(peer_id, length(sorted)), length(sorted))
    Enum.at(sorted, bucket)
  end

  @spec seed(Torrent.hash()) :: :ok
  def seed(hash), do: each_childred(hash, &Peer.seed/1)

  @spec have(Torrent.hash(), Torrent.index()) :: :ok
  def have(hash, index) do
    if Torrent.Superseed.active?(hash) do
      :ok
    else
      each_childred(hash, &Peer.have(&1, index))
    end
  end

  @doc false
  @spec confirmed_seed_count(Torrent.hash()) :: non_neg_integer()
  def confirmed_seed_count(hash) do
    hash
    |> peer_pids()
    |> Enum.count(fn pid ->
      case Peer.get_key(pid) do
        key when is_tuple(key) -> peer_seeder?(key)
        _ -> false
      end
    end)
  end

  @spec reset_rank(Torrent.hash()) :: :ok
  def reset_rank(hash), do: each_childred(hash, &Peer.reset_rank/1)

  @spec unchoke(Torrent.hash()) :: :ok
  def unchoke(hash) do
    unless torrent_offers_pieces?(hash) do
      Logger.debug(
        "[peer_upload] hash=#{Torrent.hex_encoded_hash(hash)} unchoke_skip reason=no_pieces_to_offer"
      )

      :ok
    else
      do_unchoke(hash)
    end
  end

  @spec do_unchoke(Torrent.hash()) :: :ok
  defp do_unchoke(hash) do
    ranks =
      hash
      |> peer_pids()
      |> Enum.flat_map(&safe_rank/1)
      |> Enum.sort_by(&elem(&1, 0), &(&2 > &1))

    {unchoking, choking} = split_unchoke_slots(ranks)

    if unchoking != [] or choking != [] do
      Logger.info(
        "[peer_upload] hash=#{Torrent.hex_encoded_hash(hash)} unchoke_cycle unchoking=#{length(unchoking)} choking=#{length(choking)} interested=#{length(ranks)}"
      )
    end

    Enum.each(unchoking, fn {_, id} -> safe_peer_op(fn -> Peer.unchoke(hash, id) end) end)
    Enum.each(choking, fn {_, id} -> safe_peer_op(fn -> Peer.choke(hash, id) end) end)
  end

  @spec torrent_offers_pieces?(Torrent.hash()) :: boolean()
  defp torrent_offers_pieces?(hash) do
    cond do
      Torrent.Model.downloaded?(hash) ->
        true

      true ->
        case Torrent.get(hash, [:pieces_count]) do
          [count] when is_integer(count) and count > 0 ->
            Enum.any?(0..(count - 1), &Torrent.have?(hash, &1))

          _ ->
            false
        end
    end
  catch
    :exit, _ -> false
  end

  @spec any_has_piece?(Torrent.hash(), Torrent.index()) :: boolean()
  def any_has_piece?(hash, index) do
    hash
    |> peer_pids()
    |> Enum.any?(&peer_has_index?(&1, index))
  end

  @max_active_peers 60

  @spec add(Torrent.hash(), Peer.id(), Peer.reserved(), Peer.Transport.socket()) ::
          DynamicSupervisor.on_start_child()
  def add(hash, id, reserved, socket) do
    if count(hash) >= @max_active_peers do
      {:error, :max_peers}
    else
      case start_peer_child(hash, id, reserved, socket) do
        {:ok, _pid} = ok ->
          active = count(hash)
          Logger.info("peer connected hash=#{Torrent.hex_encoded_hash(hash)} active=#{active}")
          ok

        other ->
          other
      end
    end
  end

  defp start_peer_child(hash, id, reserved, socket) do
    DynamicSupervisor.start_child(via(hash), {Peer, [id, socket, reserved]})
  catch
    :exit, _ -> {:error, :noproc}
  end

  # Short timeout for batched unchoke probes from the download pump — a stuck
  # peer must not block the controller; treat failures like choked (not counted).
  @unchoked_probe_timeout 100

  @doc false
  @spec unchoked_for_us_count(Torrent.hash()) :: non_neg_integer()
  def unchoked_for_us_count(hash) do
    case GenServer.whereis(via(hash)) do
      nil ->
        0

      _ ->
        hash
        |> peer_pids()
        |> Enum.count(&peer_unchoked_for_us?/1)
    end
  catch
    :exit, _ -> 0
  end

  @spec count(Torrent.hash()) :: non_neg_integer()
  def count(hash) do
    case GenServer.whereis(via(hash)) do
      nil ->
        0

      _ ->
        DynamicSupervisor.count_children(via(hash)).active
    end
  catch
    :exit, _ -> 0
  end

  @doc false
  @spec disconnect_all(Torrent.hash()) :: :ok
  def disconnect_all(hash), do: Torrent.Swarm.Disconnect.all(hash)

  @doc false
  @spec evict_peers(Torrent.hash(), [pid()]) :: :ok
  def evict_peers(_hash, pids) when is_list(pids) do
    Enum.each(pids, &Peer.disconnect(&1, {:shutdown, :resource_limit}))
    :ok
  end

  @spec peer_supervisors(Torrent.hash()) :: [pid()]
  def peer_supervisors(hash), do: peer_pids(hash)

  defp each_childred(hash, fun) do
    hash
    |> peer_pids()
    |> Enum.each(fun)
  end

  @spec peer_seeder_rank(pid()) :: 0 | 1 | 2
  defp peer_seeder_rank(pid) do
    case Peer.get_key(pid) do
      key when is_tuple(key) ->
        if peer_seeder?(key), do: 0, else: 1

      _ ->
        2
    end
  end

  @spec peer_seeder?(Peer.key()) :: boolean()
  defp peer_seeder?(key) do
    Peer.Controller.seeder?(key)
  catch
    :exit, _ -> false
  end

  @spec peer_pids(Torrent.hash()) :: [pid()]
  defp peer_pids(hash) do
    via(hash)
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  @spec safe_rank(pid()) :: [Peer.Controller.State.rank()]
  defp safe_rank(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        case Peer.rank(pid) do
          nil -> []
          rank -> [rank]
        end
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  @spec split_unchoke_slots([Peer.Controller.State.rank()]) ::
          {[Peer.Controller.State.rank()], [Peer.Controller.State.rank()]}
  defp split_unchoke_slots([]), do: {[], []}

  defp split_unchoke_slots(ranks) do
    {most_uploaded, list} = Enum.split(ranks, 5)

    case list do
      [] ->
        {most_uploaded, []}

      _ ->
        index = Enum.random(0..(length(list) - 1))
        {optimistic, rest} = List.pop_at(list, index)
        {[optimistic | most_uploaded], rest}
    end
  end

  @spec safe_peer_op((-> term())) :: :ok
  defp safe_peer_op(fun) do
    _ = fun.()
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec peer_unchoked_for_us?(pid()) :: boolean()
  defp peer_unchoked_for_us?(pid) when is_pid(pid) do
    with key when is_tuple(key) <- Peer.get_key(pid),
         %{choke_me?: false} <- safe_unchoked_probe(key) do
      true
    else
      _ -> false
    end
  end

  @spec safe_unchoked_probe(Peer.key()) :: map() | :error
  defp safe_unchoked_probe(key) do
    GenServer.call(
      {:via, Registry, {Registry, {key, Peer.Controller}}},
      :eviction_info,
      @unchoked_probe_timeout
    )
  catch
    :exit, _ -> :error
  end

  @spec peer_has_index?(pid(), Torrent.index()) :: boolean()
  defp peer_has_index?(pid, index) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        case Registry.keys(Registry, pid) do
          [{key, Peer}] -> Peer.Controller.has_index?(key, index)
          _ -> false
        end
      catch
        :exit, _ -> false
      end
    else
      false
    end
  end
end

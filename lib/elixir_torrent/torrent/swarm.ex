defmodule Torrent.Swarm do
  use Via

  alias Torrent.Downloads

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
    active = Downloads.active_indices(hash)

    hash
    |> peer_pids()
    |> Enum.each(fn pid ->
      case Peer.get_key(pid) do
        key when is_tuple(key) ->
          if assign_peer_to_piece?(key, index, active), do: Peer.interested(pid, index)

        _ ->
          :ok
      end
    end)
  end

  defp assign_peer_to_piece?(key, index, active_indices) do
    Peer.Controller.has_index?(key, index) and
      case Peer.Controller.download_piece(key) do
        nil -> true
        ^index -> true
        other -> other not in active_indices
      end
  catch
    :exit, _ -> false
  end

  @spec seed(Torrent.hash()) :: :ok
  def seed(hash), do: each_childred(hash, &Peer.seed/1)

  @spec have(Torrent.hash(), Torrent.index()) :: :ok
  def have(hash, index), do: each_childred(hash, &Peer.have(&1, index))

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

  @spec add(Torrent.hash(), Peer.id(), Peer.reserved(), port()) ::
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

  @spec peer_supervisors(Torrent.hash()) :: [pid()]
  def peer_supervisors(hash), do: peer_pids(hash)

  defp each_childred(hash, fun) do
    hash
    |> peer_pids()
    |> Enum.each(fun)
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

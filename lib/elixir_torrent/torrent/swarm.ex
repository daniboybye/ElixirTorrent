defmodule Torrent.Swarm do
  use Via

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
  def interested(hash, index) do
    each_childred(hash, &Peer.interested(&1, index))
  end

  @spec seed(Torrent.hash()) :: :ok
  def seed(hash), do: each_childred(hash, &Peer.seed/1)

  @spec have(Torrent.hash(), Torrent.index()) :: :ok
  def have(hash, index), do: each_childred(hash, &Peer.have(&1, index))

  @spec reset_rank(Torrent.hash()) :: :ok
  def reset_rank(hash), do: each_childred(hash, &Peer.reset_rank/1)

  @spec unchoke(Torrent.hash()) :: :ok
  def unchoke(hash) do
    {unchoking, choking} =
      with {most_uploaded, [_ | _] = list} <-
             via(hash)
             |> DynamicSupervisor.which_children()
             |> Enum.map(&(elem(&1, 1) |> Peer.rank()))
             |> Enum.filter(& &1)
             |> Enum.sort_by(&elem(&1, 0), &(&2 > &1))
             |> Enum.split(3) do
        {optimistic, list} =
          list
          |> length()
          |> (&Enum.random(0..(&1 - 1))).()
          |> (&List.pop_at(list, &1)).()

        {[optimistic | most_uploaded], list}
      end

    Enum.each(unchoking, fn {_, id} -> Peer.unchoke(hash, id) end)
    Enum.each(choking, fn {_, id} -> Peer.choke(hash, id) end)
  end

  @spec add(Torrent.hash(), Peer.id(), Peer.reserved(), port()) ::
          DynamicSupervisor.on_start_child()
  def add(hash, id, reserved, socket),
    do: DynamicSupervisor.start_child(via(hash), {Peer, [id, socket, reserved]})

  @spec count(Torrent.hash()) :: non_neg_integer()
  def count(hash), do: DynamicSupervisor.count_children(via(hash)).active

  defp each_childred(hash, fun) do
    via(hash)
    |> DynamicSupervisor.which_children()
    |> Enum.each(&(elem(&1, 1) |> fun.()))
  end
end

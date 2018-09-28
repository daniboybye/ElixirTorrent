defmodule Torrent.Swarm do
  use DynamicSupervisor

  require Via
  Via.make()

  @spec start_link(Torrent.t()) :: Supervisor.on_start()
  def start_link(%Torrent{hash: hash}) do
    DynamicSupervisor.start_link(__MODULE__, nil, name: via(hash))
  end

  @spec new_peers(Torrent.hash(), list(Peer.t())) :: :ok
  def new_peers(hash, list) do
    swarm =
      via(hash)
      |> DynamicSupervisor.which_children()
      |> Enum.map(&(elem(&1, 1) |> Peer.get_id()))
      |> MapSet.new()

    list
    |> Enum.reject(&MapSet.member?(swarm, &1.id))
    |> Enum.each(&Acceptor.send(&1, hash))
  end

  @spec interested(Torrent.hash(), Torrent.index()) :: :ok
  def interested(hash, index) do
    each_childred(hash, &Peer.interested(&1, index))
  end

  @spec seed(Torrent.hash()) :: :ok
  def seed(hash), do: each_childred(hash, &Peer.seed/1)

  @spec broadcast_have(Torrent.hash(), Torrent.index()) :: :ok
  def broadcast_have(hash, index), do: each_childred(hash, &Peer.have(&1, index))

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

  @spec add_peer(Torrent.hash(), Peer.id(), Peer.reserved(), port()) ::
          DynamicSupervisor.on_start_child()
  def add_peer(hash, id, reserved, socket) do
    DynamicSupervisor.start_child(via(hash), {Peer, {id, hash, socket, reserved}})
  end

  @spec count(Torrent.hash()) :: %{
          specs: non_neg_integer(),
          active: non_neg_integer(),
          supervisors: non_neg_integer(),
          workers: non_neg_integer()
        }
  def count(hash), do: DynamicSupervisor.count_children(via(hash))

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 0)
  end

  defp each_childred(hash, fun) do
    DynamicSupervisor.which_children(via(hash))
    |> Enum.each(&(elem(&1, 1) |> fun.()))
  end
end

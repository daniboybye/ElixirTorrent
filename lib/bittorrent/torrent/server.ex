defmodule Bittorrent.Torrent.Server do
  use GenServer

  import Bittorrent

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(torrent_name) do 
    send(self(),:init)
    {:ok, torent_name}
  end

  def handle_info(:init,torrent_name) do
    state = Registry.get(torrent_name)
    peers = PeerDiscovery.get(state.info_hash)
    swarm  = get_swarm()

    

    {:noreply, {swarm,state} }
  end

  defp get_swarm() do
    Torrents
    |> DynamicSupervisor.which_child()
    |> Enum.map(&Supervisor.which_child()/1)
    |> Enum.find(&Enum.find(&1,fn {_,x,_,_} -> x == self() end))
    |> Enum.find(fn {_,x,_,_} -> x != self() end)
  end
end

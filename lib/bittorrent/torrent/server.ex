defmodule Bittorrent.Torrent.Server do
  use GenServer

  import Bittorrent
  require Via

  Via.make()

  @doc """
  key = info_hash 
  """

  def start_link(key), do: GenServer.start_link(__MODULE__, key, via(key))

  def get_pieces_size(server) do
    GenServer.call(server,:get_pices_size)
  end

  def init({torrent_name, parent}) do
    send(self(),:init)
    {:ok, {parent,torent_name}}
  end

  def handle_call(:get_pices_size,_
    {_,_,%Torrent.Struct{pieces_size: pieces_size} } = state) do
    {:reply,pieces_size,state}
  end

  def handle_cast({:add_peer,args},{swarm,_,_} = state) do
    DynamicSupervisor.start_child(
      swarm,
      {Peer, {self(),args} }
    )
    {:noreply,state}
  end

  def handle_info(:init,{parent,torrent_name}) do
    {swarm, file_handle} = get_swarm_filehandle(parent)
    state = Registry.get(torrent_name)
    
    state.info_hash
    |> PeerDiscovery.get()
    |> Enum.each(&DynamicSupervisor.start_child(
      swarm,
      Handshake, :send, [&1,state.info_hash,Registry.peer_id,self()]
    )

    {:noreply, {swarm,file_handle,state} }
  end
end

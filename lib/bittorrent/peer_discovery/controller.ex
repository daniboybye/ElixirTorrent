defmodule Bittorrent.PeerDiscovery.Controller do
  use GenServer

  import Bittorent
  import Bittorent.PeerDiscovery

  @timeout_refresh 600_000 #10minutes

  def start_link() do
    GenServer.start_link(__MODULE__,nil, name: __MODULE__)
  end

  def first_request(file_name) do
    GenServer.call(
      __MODULE__, 
      {:first_request, file_name}, 
      :infinity
    )
  end

  def has_hash?(hash) do
    GenServer.call(__MODULE__,{:has_hash?,hash})
  end

  def get(key), do: GenServer.call(__MODULE__,{:get,key})

  def put(pair), do: GenServer.cast(__MODULE__,{:put,pair})

  def delete(key), do: GenServer.cast(__MODULE__,{:delete,key})

  def init(_) do
    send(self(), :refresh) 
    {:ok, %State{}}
  end

  def handle_call({:has_hash?,hash},_,%State{peers: map} = state) do
    {:reply,Map.has_key?(map,hash),state}
  end

  def handle_call({:get,hash},_,%State{peers: peers} = state) do
    {:reply,Map.get(peers,hash),state}
  end

  def handle_call({:first_request, file_name},from, 
  %State{requests: requests} = state) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(
        Requests, 
        Tracker, 
        :first_request!,
        [file_name, PeerDiscovery.peer_id(),PeerDiscovery.port()]
      )
    {:noreply, %State{state | requests: Map.new(requests,ref,from) }}
  end

  def handle_cast({:put,{hash,peers}},%State{peers: map} = state) do
    {:noreply, %State{state | peers: Map.new(map,hash,peers) }}
  end

  def handle_cast({:delete,hash},%State{peers: peers} = state) do
    {:noreply, %State{state | peers: Map.delete(peers,hash) }}
  end

  def handle_info(:refresh, %State{peers: map} = state) do
    map
    |> Map.keys()
    |> Torrent.get()
    |> Enum.each(fn %Torrent.Struct{hash: hash} = torrent ->
      Task.Supervisor.start_child(
        Requests,
        fn -> 
          {
            hash, 
            Tracker.request!(
              torrent, 
              PeerDiscovery.peer_id(),
              PeerDiscovery.port()
            )
          }
          |> put()
        end,
        ) end
      )
    send_after(self(),:refresh, @timeout_refresh)
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %State{requests: requests} = state) do
    {from, requests} = Map.pop(requests,ref)
    GenServer.reply(from,:error)
    {:noreply,%State{state | requests: requests}}
  end

  def handle_info({ref, {torrent, peers}}, %State{requests: requests, peers: map} = state) do
    {from, requests} = Map.pop(requests,ref)
    Torrents.start_torrent(torrent)
    GenServer.reply(from, torrent.hash)
    
    {
      :noreply,
      %State{state | 
        requests: requests, 
        peers: Map.new(map,torrent.hash,peers)
      }
    }
  end
end
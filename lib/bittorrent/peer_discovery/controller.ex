defmodule Bittorrent.PeerDiscovery.Controller do
  use GenServer

  import Bittorent
  import Bittorent.PeerDiscovery

  @timeout_refresh 600_000 #10minutes

  def start_link() do
    GenServer.start_link(__MODULE__,:ok, name: __MODULE__)
  end

  def first_request(file_name) do
    GenServer.call(
      __MODULE__, 
      {:first_request, file_name}, 
      :infinity
    )
  end

  def get(key) do
    GenServer.call(__MODULE__,{:get,key})
  end

  def put(pair) do
    GenServer.cast(__MODULE__,{:put,pair})
  end

  def delete(key) do
    GenServer.cast(__MODULE__,{:delete,key})
  end

  def init(:ok) do
    send(self(), :refresh) 
    {:ok, %State{}}
  end

  def handle_call({:get,info_hash},_,%State{peers: peers} = state) do
    {:reply,Map.get(peers,info_hash),state}
  end

  def handle_call({:first_request, file_name},from, 
  %State{requests: requests} = state) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(
        Requests, 
        Tracker, :first_request!,
        [file_name,
        PeerDiscovery.peer_id(),
        PeerDiscovery.port()],
        shitdown: :infinity)

    {:noreply, %State{state | requests: Map.new(requests,ref,from) }}
  end

  def handle_cast({:put,{info_hash,peers}},%State{peers: map} = state) do
    {:noreply, %State{state | peers: Map.new(map,info_hash,peers) }}
  end

  def handle_cast({:delete,info_hash},%State{peers: peers} = state) do
    {:noreply, %State{state | peers: Map.delete(peers,info_hash) }}
  end

  def handle_info(:refresh,%State{} = state) do
    Registry.get()
    |> Enum.each(fn %Torrent.Struct{info_hash: info_hash} = torrent ->
      Task.Supervisor.start_child(
        Requests,
        fn -> 
          {info_hash, Tracker.request!(torrent,
          PeerDiscovery.peer_id(),
          PeerDiscovery.port())
          |> put() end,
        shitdown: :infinity
        ) end
      )
    send_after(self(),:refresh, @timeout_refresh)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %State{requests: requests} = state) do
    {from, requests} = Map.pop(requests,ref)
    GenServer.reply(from,:error)
    {:noreply,%State{state | requests: requests}}
  end

  def handle_info({ref, {torrent, peers}}, %State{requests: requests, peers: map} = state) do
    {from, requests} = Map.pop(requests,ref)
    Registry.start_torrent(torrent)
    GenServer.reply(from,torrent.struct["info"]["name"])
    
    {:noreply,%State{state | 
      requests: requests, 
      peers: Map.new(map,torrent.info_hash,peers)}}
  end
end
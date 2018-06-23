defmodule Bittorrent.Registry do
  use GenServer

  import Bittorrent

  def start_link() do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get() do
    GenServer.call(__MODULE__,:get)
  end

  def get(torrent_name) do
    GenServer.call(__MODULE__,{:get,torrent_name})
  end

  def start_torrent(%Torrent.Struct{} = torrent) do
    GenServer.cast(__MODULE__,{:start_torrent, torrent})
  end

  def get_torrent(info_hash) do
    GenServer.call(__MODULE__,{:get_torrent,info_hash})
  end

  def init(:ok), do: {:ok, []}

  def handle_call(:get,_,state) do
    {:reply,state,state}
  end

  def handle_call({:get, name},_,list) do
    {:reply,get_by_name(name,),list}
  end

  def handle_call({:get_torrent,info_hash},_,list) do
    case get_by_hash(list,info_hash) do
      nil -> 
        {:reply,:error,list}
      torrent ->
        server = Torrent.Struct.get_server(torrent)
        {:reply,{:ok,server},list}
    end
  end

  def handle_cast({:start_torrent, torrent}, state) do
    {:ok, pid} = Dynamicsupervisor.start_child(
      Torrents,
      {Torrent,torrent.struct["info"]["name"]}
    )
    Procces.monitor(pid)
    {:noreply,[%Torrent.Struct{torrent | pid: pid} | state]}
  end

  def handle_info({:DOWN, _ref, :process, pid, _},state) do
    {torrent, list} = state
    |> Enum.find(fn x -> x.pid == pid end)
    |> (&List.pop_at(state,&1)).()
    
    IO.puts("problem with ",torrent.struct["info"]["name"])
    {:noreply,list}
  end

  defp get_by_name(name, list) do
    Enum.find(list,fn x -> x.struct["info"]["name"] == name end)
  end

  defp get_by_hash(hash,list) do
    Enum.find(list, fn torrent -> torrent.info_hash == hash end)
  end
end
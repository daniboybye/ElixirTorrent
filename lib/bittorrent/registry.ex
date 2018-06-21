defmodule Bittorrent.Registry do
  use GenServer

  import Bittorrent

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
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

  def init(_), do: {:ok, []}

  def handle_call(:get,_,state) do
    {:reply,state,state}
  end

  def handle_call({:get, name},_,state) do
    {:reply,get(name,state),state}
  end

  def handle_cast({:start_torrent, torrent}, state) do
    {:ok, _} = Dynamicsupervisor.start_child(
      Torrents,
      {Torrent,torrent.struct["info"]["name"]}
    )
    {:noreply,[torrent | state]}
  end

  defp get(name,list) do
    Enum.find(list,fn x -> x.struct["info"]["name"] == name end)
  end

end
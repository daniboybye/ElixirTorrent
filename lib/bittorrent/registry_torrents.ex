defmodule Bittorrent.RegistryTorrents do
  use GenServer

  import Bittorrent

  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def get(), do: GenServer.call(__MODULE__,:get)

  def start_torrent(%Torrent.Struct{} = torrent) do
    GenServer.cast(__MODULE__,{:start_torrent, torrent})
  end

  def has_hash?(info_hash) do
    GenServer.call(__MODULE__,{:has_hash?,info_hash})
  end

  def get_torrent(info_hash) do
    GenServer.call(__MODULE__,{:get_torrent,info_hash})
  end

  def init(_), do: {:ok, %{}}

  def handle_call(:get,_,state), do: {:reply,state,state}

  def handle_cast({:has_hash?,hash},_,state) do
    {:reply, Map.has_key?(state,hash),state}
  end

  def handle_call({:get_torrent, hash}, _, state) do
    {:reply, Map.fetch(state,hash), state}
  end

  def handle_cast({:start_torrent, torrent}, state) do
    Dynamicsupervisor.start_child(
      Torrents,
      {Torrent,torrent.struct["info"]["name"]}
    )
    {:noreply, Map.put_new(state,torrent.info_hash,torrent)}
  end
end
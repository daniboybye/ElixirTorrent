defmodule Bittorent.Acceptor.BlackList do
  use GenServer

  def put(peer_id) do
    GenServer.cast(__MODULE__, {:put, peer_id})
  end

  def member?(peer_id) do
    GenServer.call(__MODULE__, {:member?, peer_id})
  end

  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_), do: {:ok, MapSet.new()}

  def handle_call({:member?, peer_id}, _, state) do
    {:reply, MapSet.member?(state, peer_id), state}
  end

  def handle_cast({:put, peer_id}, state) do
    {:noreply, MapSet.put?(state, peer_id)}
  end
end

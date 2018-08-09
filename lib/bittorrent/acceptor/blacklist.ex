defmodule Acceptor.BlackList do
  use GenServer

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec put(peer_id :: Peer.peer_id()) :: :ok
  def put(peer_id), do: GenServer.cast(__MODULE__, peer_id)

  @spec member?(Peer.peer_id()) :: boolean()
  def member?(peer_id), do: GenServer.call(__MODULE__, peer_id)

  def init(_), do: {:ok, MapSet.new()}

  def handle_call(peer_id, _, state) do
    {:reply, MapSet.member?(state, peer_id), state}
  end

  def handle_cast(peer_id, state) do
    {:noreply, MapSet.put(state, peer_id)}
  end
end

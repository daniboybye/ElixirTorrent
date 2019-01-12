defmodule Acceptor.BlackList do
  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  @spec put(Peer.id()) :: :ok
  def put(peer_id), do: GenServer.cast(__MODULE__, peer_id)

  @spec member?(Peer.id()) :: boolean()
  def member?(peer_id), do: GenServer.call(__MODULE__, peer_id)

  def init(_), do: {:ok, MapSet.new()}

  def handle_call(peer_id, _, state),
    do: {:reply, MapSet.member?(state, peer_id), state}

  def handle_cast(peer_id, state),
    do: {:noreply, MapSet.put(state, peer_id)}
end

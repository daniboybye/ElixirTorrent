defmodule Acceptor.BlackList do
  @moduledoc """
  GenServer holding peer IDs rejected after failed handshakes (BEP 3 peer churn guard).
  """

  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  @spec put(Peer.id()) :: :ok
  def put(peer_id), do: GenServer.cast(__MODULE__, peer_id)

  @spec member?(Peer.id()) :: boolean()
  def member?(peer_id), do: GenServer.call(__MODULE__, peer_id)

  @spec init(term()) :: {:ok, MapSet.t(Peer.id())}
  def init(_), do: {:ok, MapSet.new()}

  @spec handle_call(Peer.id(), GenServer.from(), MapSet.t(Peer.id())) ::
          {:reply, boolean(), MapSet.t(Peer.id())}
  def handle_call(peer_id, _, state),
    do: {:reply, MapSet.member?(state, peer_id), state}

  @spec handle_cast(Peer.id(), MapSet.t(Peer.id())) :: {:noreply, MapSet.t(Peer.id())}
  def handle_cast(peer_id, state),
    do: {:noreply, MapSet.put(state, peer_id)}
end

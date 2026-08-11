defmodule PeerWireTest.ControllerCapture do
  @moduledoc false
  use GenServer

  @spec start_link(Peer.key(), pid()) :: GenServer.on_start()
  def start_link(key, test_pid) do
    GenServer.start_link(__MODULE__, {key, test_pid},
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  @spec whereis(Peer.key()) :: pid() | nil
  def whereis(key), do: GenServer.whereis({:via, Registry, {Registry, {key, Peer.Controller}}})

  @impl GenServer
  def init({key, test_pid}), do: {:ok, {key, test_pid}}

  @impl GenServer
  def handle_cast({fun, args}, {key, test_pid}) when is_atom(fun) and is_list(args) do
    send(test_pid, {:controller, fun, args})
    {:noreply, {key, test_pid}}
  end
end

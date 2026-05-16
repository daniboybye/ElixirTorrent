defmodule PeerWireTest.SentCollector do
  @moduledoc false
  use GenServer

  def start_link(key, test_pid) do
    GenServer.start_link(__MODULE__, {key, test_pid},
      name: {:via, Registry, {Registry, {key, Peer.Sender}}}
    )
  end

  @impl GenServer
  def init({key, test_pid}), do: {:ok, {key, test_pid}}

  @impl GenServer
  def handle_cast(msg, {key, test_pid}) do
    send(test_pid, {:sent, msg})
    {:noreply, {key, test_pid}}
  end

  @impl GenServer
  def handle_call({:socket_send_raw, data}, _from, {key, test_pid}) do
    send(test_pid, {:sent, {:socket_raw, data}})
    {:reply, :ok, {key, test_pid}}
  end

  @impl GenServer
  def handle_call(:activate, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_call(:deactivate, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_call({:send_operations, ops}, _from, {key, test_pid}) do
    send(test_pid, {:send_operations, ops})
    {:reply, :ok, {key, test_pid}}
  end
end

defmodule HashTransferSentStub do
  @moduledoc false
  use GenServer

  def start_link(key, test_pid) do
    GenServer.start_link(__MODULE__, {key, test_pid},
      name: {:via, Registry, {Registry, {key, Peer.Sender}}}
    )
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast(msg, {key, test_pid}) do
    send(test_pid, {:sent, msg})
    {:noreply, {key, test_pid}}
  end

  @impl true
  def handle_call({:socket_send_raw, _data}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call(:activate, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call(:deactivate, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:send_operations, ops}, _from, {key, test_pid}) do
    send(test_pid, {:send_operations, ops})
    {:reply, :ok, {key, test_pid}}
  end
end

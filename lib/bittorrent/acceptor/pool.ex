defmodule Acceptor.Pool do
  use GenServer, start: {__MODULE__, :start_link, []}

  @spec start_link() :: GenServer.on_start()
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec give_control(Acceptor.socket()) :: :ok | no_return()
  def give_control(socket) do
    pid = GenServer.whereis(__MODULE__)
    :ok = :gen_tcp.controlling_process(socket, pid)
    GenServer.cast(pid, {:give_control, socket})
  end

  @spec close(Acceptor.socket()) :: :ok
  def close(socket), do: GenServer.cast(__MODULE__, {:close, socket})

  @spec remove_control(Acceptor.socket()) :: :ok | {:error, any()}
  def remove_control(socket) do
    GenServer.call(__MODULE__, {:remove_control, socket})
  end

  def init(_), do: {:ok, MapSet.new()}

  def handle_call({:remove_control, socket}, {pid,_}, state) do
    {:reply, :gen_tcp.controlling_process(socket, pid), MapSet.delete(state, socket)}
  end

  def handle_cast({:give_control, socket}, state) do
    {:noreply, MapSet.put(state, socket)}
  end

  def handle_cast({:close, socket}, state) do
    :gen_tcp.close(socket)
    {:noreply, MapSet.delete(state, socket)}
  end
end

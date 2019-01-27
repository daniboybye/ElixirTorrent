defmodule PeerDiscovery.ConnectionIds do
  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  @moduledoc """
    UDP Tracker Protocol only
  """

  alias __MODULE__.State

  @timeout 60_000

  @spec get(port(), :inet.ip_address(), :inet.port_number()) ::
          {:ok, Tracker.connection_id()} | Tracker.Error.t() | :error
  def get(socket, ip, port) do
    GenServer.call(
      __MODULE__,
      [socket, ip, port],
      90 * 60 * 1_000
    )
  end

  def init(_), do: {:ok, %State{}}

  def handle_call([socket, ip, port], from, state) do
    key = {ip, port}
    case Map.fetch(state.ids, key) do
      {:ok, [_ | _]} ->
        {:noreply, update_in(state, [Access.key!(:ids), key], &[from | &1])}

      {:ok, connection_id} ->
        {:reply, {:ok, connection_id}, state}

      :error ->
        %Task{ref: ref} =
          Task.Supervisor.async_nolink(
            PeerDiscovery.Requests,
            Tracker,
            :udp_connect,
            [socket, ip, port]
          )

        {:noreply,
         %State{
           state
           | ids: Map.put(state.ids, key, [from]),
             requests: Map.put(state.requests, ref, key)
         }}
    end
  end

  def handle_info({:timeout, key}, state),
    do: {:noreply, Map.update!(state, :ids, &Map.delete(&1, key))}

  def handle_info({:DOWN, _, :process, _, :normal}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: failure(ref, state, :error)

  def handle_info({ref, %Tracker.Error{} = error}, state),
    do: failure(ref, state, error)

  def handle_info({ref, <<connection_id::binary>>}, state) do
    {key, state} = pop_in(state, [Access.key!(:requests), ref])
    Process.send_after(self(), {:timeout, key}, @timeout)

    state =
      update_in(state, [Access.key!(:ids), key], fn list ->
        Enum.each(list, &GenServer.reply(&1, {:ok, connection_id}))
        connection_id
      end)

    {:noreply, state}
  end

  defp failure(ref, state, error) do
    {key, state} = pop_in(state, [Access.key!(:requests), ref])
    {list, state} = pop_in(state, [Access.key!(:ids), key])
    Enum.each(list, &GenServer.reply(&1, error))
    {:noreply, state}
  end
end

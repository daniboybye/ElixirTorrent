defmodule PeerDiscovery.ConnectionIds do
  use GenServer, start: {__MODULE__, :start_link, []}

  @moduledoc """
    UDP Tracker Protocol only
  """

  alias __MODULE__.State

  @timeout 60_000

  @spec start_link() :: GenServer.on_start()
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec get(Tracker.announce(), port(), :inet.ip_address(), :inet.port_number()) ::
          Tracker.connection_id() | Tracker.Error.t() | nil
  def get(announce, socket, ip, port) do
    GenServer.call(
      __MODULE__,
      {announce, socket, ip, port},
      2 * 60 * 60 * 1_000
    )
  end

  def init(_), do: {:ok, %State{}}

  def handle_call({announce, socket, ip, port}, from, state) do
    case Map.fetch(state.ids, announce) do
      {:ok, [_ | _]} ->
        {:noreply, update_in(state, [Access.key!(:ids), announce], &[from | &1])}

      {:ok, connection_id} ->
        {:reply, connection_id, state}

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
           | ids: Map.put(state.ids, announce, [from]),
             requests: Map.put(state.requests, ref, announce)
         }}
    end
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    failure(ref, state, nil)
  end

  def handle_info({ref, %Tracker.Error{} = error}, state) when is_reference(ref) do
    failure(ref, state, error)
  end

  def handle_info({ref, connection_id}, state) when is_reference(ref) do
    {announce, state} = pop_in(state, [Access.key!(:requests), ref])
    Process.send_after(self(), {:timeout, announce}, @timeout)

    {:noreply,
     update_in(state, [Access.key!(:ids), announce], fn list ->
       Enum.each(list, &GenServer.reply(&1, connection_id))
       connection_id
     end)}
  end

  def handle_info({:timeout, announce}, state) do
    state
    |> Map.update!(:ids, &Map.delete(&1, announce))
    |> (&{:noreply, &1}).()
  end

  defp failure(ref, state, error) do
    {announce, state} = pop_in(state, [Access.key!(:requests), ref])
    {list, state} = pop_in(state, [Access.key!(:ids), announce])
    Enum.each(list, &GenServer.reply(&1, error))
    {:noreply, state}
  end
end

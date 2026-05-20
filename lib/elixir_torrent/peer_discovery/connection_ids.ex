defmodule PeerDiscovery.ConnectionIds do
  @moduledoc """
  Caches BEP 15 UDP tracker `connection_id` values per tracker endpoint and local UDP port.

  BEP 15 § UDP connections: a client may reuse a connection_id for one minute after receipt;
  we expire cache entries after `Tracker.UDP.connection_id_lifetime_ms/0` (60 s).

  UDP connect uses BEP 15 exponential backoff (up to ~127 min). Waiters are capped at
  `@request_timeout_ms` so parallel announces do not block on dead trackers until the
  90-minute GenServer.call timeout and crash their Tasks.
  """

  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  alias __MODULE__.State
  alias Tracker.Error

  require Logger

  # BEP 15 § UDP connections — connection_id valid for one minute on the client.
  @cache_lifetime_ms Tracker.UDP.connection_id_lifetime_ms()
  @request_timeout_ms 45_000
  @call_timeout_ms @request_timeout_ms + 5_000
  @retry_after_timeout_sec 60

  @spec get(port(), :inet.ip_address(), :inet.port_number()) ::
          {:ok, Tracker.connection_id()} | Tracker.Error.t() | :error
  def get(socket, ip, port) do
    GenServer.call(__MODULE__, [socket, ip, port], @call_timeout_ms)
  end

  @doc """
  Drops a cached BEP 15 connection_id so the next `get/3` performs a fresh connect.

  Used when a tracker reports the connection id expired (BEP 15 § UDP connections).
  """
  @spec invalidate(port(), :inet.ip_address(), :inet.port_number()) :: :ok
  def invalidate(socket, ip, port) do
    GenServer.cast(__MODULE__, {:invalidate, socket, ip, port})
  end

  @spec init(term()) :: {:ok, State.t()}
  def init(_), do: {:ok, %State{}}

  @spec handle_cast({:invalidate, port(), :inet.ip_address(), :inet.port_number()}, State.t()) ::
          {:noreply, State.t()}
  def handle_cast({:invalidate, socket, ip, port}, %State{} = state) do
    {:ok, local_port} = :inet.port(socket)
    key = {ip, port, local_port}
    {:noreply, update_in(state, [Access.key!(:ids)], &Map.delete(&1, key))}
  end

  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, {:ok, Tracker.connection_id()} | Tracker.Error.t() | :error, State.t()}
          | {:noreply, State.t()}
  def handle_call([socket, ip, port], from, %State{} = state) do
    # Some UDP trackers appear to bind connection_id validity to the client's source port.
    # We open new UDP sockets over time, so cache connection_ids per (tracker endpoint, local port).
    {:ok, local_port} = :inet.port(socket)
    key = {ip, port, local_port}

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

        timer_ref = Process.send_after(self(), {:request_timeout, ref}, @request_timeout_ms)

        {:noreply,
         %{
           state
           | ids: Map.put(state.ids, key, [from]),
             requests: Map.put(state.requests, ref, {key, timer_ref})
         }}
    end
  end

  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info({:timeout, key}, state),
    do: {:noreply, Map.update!(state, :ids, &Map.delete(&1, key))}

  def handle_info({:request_timeout, ref}, state) do
    case Map.fetch(state.requests, ref) do
      {:ok, {key, timer_ref}} ->
        Process.cancel_timer(timer_ref)
        timeout_error = %Error{reason: :timeout, retry_in: @retry_after_timeout_sec}

        Logger.debug(
          "[tracker_connection_id] timeout endpoint=#{inspect(key)} after #{@request_timeout_ms}ms"
        )

        {:noreply, fail_waiters(state, ref, key, timeout_error)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case pop_request(state, ref) do
      {nil, state} -> {:noreply, state}
      {{key, _timer_ref}, state} -> {:noreply, fail_waiters(state, ref, key, :error)}
    end
  end

  def handle_info({ref, %Error{} = error}, state) do
    case pop_request(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {{key, timer_ref}, state} ->
        Process.cancel_timer(timer_ref)
        {:noreply, fail_waiters(state, ref, key, error)}
    end
  end

  def handle_info({ref, <<connection_id::binary>>}, state) do
    case pop_request(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {{key, timer_ref}, state} ->
        Process.cancel_timer(timer_ref)
        Process.send_after(self(), {:timeout, key}, @cache_lifetime_ms)

        state =
          update_in(state, [Access.key!(:ids), key], fn list ->
            Enum.each(list, &GenServer.reply(&1, {:ok, connection_id}))
            connection_id
          end)

        {:noreply, state}
    end
  end

  defp pop_request(%State{} = state, ref) do
    pop_in(state, [Access.key!(:requests), ref])
  end

  defp fail_waiters(%State{} = state, ref, key, error) do
    {_entry, state} = pop_in(state, [Access.key!(:requests), ref])
    {list, state} = pop_in(state, [Access.key!(:ids), key])

    if list do
      Enum.each(list, &GenServer.reply(&1, error))
    end

    state
  end
end

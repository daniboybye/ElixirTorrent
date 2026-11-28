defmodule Magnet.Fetcher.ConnectionLimit do
  @moduledoc false

  # Caps the direct BEP 9 metadata connections of all magnet fetches together, so
  # a batch of magnets cannot flood the NAT with half-open dials.
  #
  # Slots belong to the process that acquired them. The limiter monitors it: a
  # fetch round is killed when its magnet is cancelled, and a killed process never
  # runs its `after` release.

  use GenServer

  @max_total 32

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Blocks until `count` slots are free. Waiting is the normal case once a few
  magnets are fetching at once, so there is no default deadline. A caller that
  gives up on a finite `timeout` holds nothing afterwards.
  """
  @spec acquire(pos_integer(), timeout()) :: :ok
  def acquire(count, timeout \\ :infinity) when is_integer(count) and count > 0 do
    request = make_ref()

    try do
      GenServer.call(__MODULE__, {:acquire, count, request}, timeout)
    catch
      :exit, {:timeout, _call} = reason ->
        GenServer.cast(__MODULE__, {:cancel, self(), count, request})
        exit(reason)
    end
  end

  @spec release(non_neg_integer()) :: :ok
  def release(count) when is_integer(count) and count >= 0 do
    if count > 0, do: GenServer.cast(__MODULE__, {:release, self(), count})
    :ok
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{in_use: 0, clients: %{}, waiters: []}}

  @impl GenServer
  def handle_call({:acquire, count, request}, {pid, _tag} = from, state) do
    state = track(state, pid)
    # Appending keeps the queue FIFO; it holds at most one entry per pending magnet.
    waiters = state.waiters ++ [{request, from, count}]
    {:noreply, grant_waiters(%{state | waiters: waiters})}
  end

  @impl GenServer
  def handle_cast({:release, pid, count}, state) do
    state = free(state, pid, count)
    {:noreply, grant_waiters(state)}
  end

  def handle_cast({:cancel, pid, count, request}, state) do
    state =
      case List.keytake(state.waiters, request, 0) do
        {_waiter, waiters} -> %{state | waiters: waiters}
        # Granted just as the caller gave up: the reply is lost, take the slots back.
        nil -> free(state, pid, count)
      end

    {:noreply, grant_waiters(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {client, clients} = Map.pop(state.clients, pid, %{held: 0})

    waiters =
      Enum.reject(state.waiters, fn {_request, {waiter, _tag}, _count} -> waiter == pid end)

    state = %{state | clients: clients, waiters: waiters, in_use: state.in_use - client.held}
    {:noreply, grant_waiters(state)}
  end

  @spec track(map(), pid()) :: map()
  defp track(%{clients: clients} = state, pid) do
    clients = Map.put_new_lazy(clients, pid, fn -> %{ref: Process.monitor(pid), held: 0} end)
    %{state | clients: clients}
  end

  @spec free(map(), pid(), non_neg_integer()) :: map()
  defp free(%{clients: clients} = state, pid, count) do
    case clients do
      %{^pid => %{held: held} = client} ->
        freed = min(count, held)
        clients = %{clients | pid => %{client | held: held - freed}}
        %{state | clients: clients, in_use: state.in_use - freed}

      _ ->
        state
    end
  end

  @spec grant_waiters(map()) :: map()
  defp grant_waiters(%{waiters: [{_request, {pid, _tag} = from, count} | rest]} = state)
       when state.in_use + count <= @max_total do
    GenServer.reply(from, :ok)
    clients = Map.update!(state.clients, pid, &%{&1 | held: &1.held + count})

    grant_waiters(%{state | clients: clients, waiters: rest, in_use: state.in_use + count})
  end

  defp grant_waiters(state), do: state
end

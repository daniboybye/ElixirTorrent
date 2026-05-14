defmodule Magnet.Fetcher.ConnectionLimit do
  @moduledoc false

  use GenServer

  @max_total 32

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec acquire(pos_integer(), timeout()) :: :ok
  def acquire(count, timeout \\ 30_000) when is_integer(count) and count > 0 do
    GenServer.call(__MODULE__, {:acquire, count}, timeout)
  end

  @spec release(non_neg_integer()) :: :ok
  def release(count) when is_integer(count) and count >= 0 do
    if count > 0, do: GenServer.cast(__MODULE__, {:release, count})
    :ok
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{in_use: 0, waiters: :queue.new()}}

  @impl GenServer
  def handle_call({:acquire, count}, from, %{in_use: in_use, waiters: waiters} = state) do
    if in_use + count <= @max_total do
      {:reply, :ok, %{state | in_use: in_use + count}}
    else
      {:noreply, %{state | waiters: :queue.in({count, from}, waiters)}}
    end
  end

  @impl GenServer
  def handle_cast({:release, count}, %{in_use: in_use, waiters: waiters} = state) do
    in_use = max(in_use - count, 0)
    {waiters, in_use} = grant_waiters(waiters, in_use)
    {:noreply, %{state | in_use: in_use, waiters: waiters}}
  end

  @spec grant_waiters(:queue.queue(), non_neg_integer()) ::
          {:queue.queue(), non_neg_integer()}
  defp grant_waiters(waiters, in_use) do
    case :queue.out(waiters) do
      {{:value, {count, from}}, rest} when in_use + count <= @max_total ->
        GenServer.reply(from, :ok)
        grant_waiters(rest, in_use + count)

      _ ->
        {waiters, in_use}
    end
  end
end

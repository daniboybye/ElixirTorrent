defmodule Acceptor.BlackList do
  @moduledoc """
  Peer IDs to refuse for a while after they broke the wire protocol (BEP 3 peer
  churn guard).

  Entries expire. This used to be a `MapSet` that only grew, so one bad frame
  excluded a peer for the rest of the session, across every torrent — and on a
  CGNAT host, where a torrent runs on 1-8 peers, that is the swarm. A live
  ten-minute debug run banned 352 peer IDs, mostly mainstream clients, while
  eight of nine torrents could not get past three connections.

  A ban is a hedge against a peer that will misbehave again, and re-testing it
  costs one connection, so it does not need to outlive the failure by much.
  """

  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  @ttl_ms 30 * 60 * 1_000
  @sweep_ms 60_000
  # Bounds memory on a long session. Well past what a healthy run reaches, so
  # hitting it means something is banning indiscriminately.
  @max_entries 2_000

  @spec put(Peer.id()) :: :ok
  def put(peer_id), do: GenServer.cast(__MODULE__, peer_id)

  @spec member?(Peer.id()) :: boolean()
  def member?(peer_id), do: GenServer.call(__MODULE__, peer_id)

  @spec init(term()) :: {:ok, %{optional(Peer.id()) => integer()}}
  def init(_) do
    schedule_sweep()
    {:ok, %{}}
  end

  @spec handle_call(Peer.id(), GenServer.from(), %{optional(Peer.id()) => integer()}) ::
          {:reply, boolean(), %{optional(Peer.id()) => integer()}}
  def handle_call(peer_id, _, state) do
    case Map.fetch(state, peer_id) do
      {:ok, expires_at} ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:reply, true, state}
        else
          {:reply, false, Map.delete(state, peer_id)}
        end

      :error ->
        {:reply, false, state}
    end
  end

  @spec handle_cast(Peer.id(), %{optional(Peer.id()) => integer()}) ::
          {:noreply, %{optional(Peer.id()) => integer()}}
  def handle_cast(peer_id, state) do
    state
    |> Map.put(peer_id, System.monotonic_time(:millisecond) + @ttl_ms)
    |> cap()
    |> then(&{:noreply, &1})
  end

  @spec handle_info(:sweep, %{optional(Peer.id()) => integer()}) ::
          {:noreply, %{optional(Peer.id()) => integer()}}
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    schedule_sweep()
    {:noreply, Map.reject(state, fn {_id, expires_at} -> expires_at <= now end)}
  end

  defp cap(state) when map_size(state) <= @max_entries, do: state

  defp cap(state) do
    {oldest, _} = Enum.min_by(state, fn {_id, expires_at} -> expires_at end)
    Map.delete(state, oldest)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end

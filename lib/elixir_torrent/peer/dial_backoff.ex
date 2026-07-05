defmodule Peer.DialBackoff do
  @moduledoc false

  use GenServer

  @table :peer_dial_backoff
  @default_ttl_ms 5 * 60 * 1_000
  @timeout_ttl_ms 2 * 60 * 1_000
  @under_target_timeout_ttl_ms 45 * 1_000
  @sweep_ms 60_000

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec filter([Peer.t()], Torrent.hash(), non_neg_integer()) :: [Peer.t()]
  def filter(peers, hash, min_count \\ 0) when is_list(peers) and is_integer(min_count) do
    now = System.monotonic_time(:millisecond)

    {allowed, blocked} =
      Enum.split_with(peers, fn %Peer{ip: ip, port: port} ->
        not blocked?(hash, ip, port, now)
      end)

    if min_count <= 0 or length(allowed) >= min_count or blocked == [] do
      allowed
    else
      need = min(min_count - length(allowed), length(blocked))
      Enum.take(blocked, need) ++ allowed
    end
  catch
    :exit, _ -> peers
  end

  @spec record(Torrent.hash(), :inet.ip_address(), :inet.port_number(), term()) :: :ok
  def record(hash, ip, port, reason) do
    ttl = ttl_for(hash, reason)
    GenServer.cast(__MODULE__, {:record, hash, ip, port, ttl})
  catch
    :exit, _ -> :ok
  end

  defp ttl_for(hash, reason) do
    base =
      case reason do
        :timeout -> @timeout_ttl_ms
        :closed -> @timeout_ttl_ms
        _ -> @default_ttl_ms
      end

    if under_target?(hash), do: min(base, @under_target_timeout_ttl_ms), else: base
  end

  defp under_target?(hash) do
    Torrent.Swarm.count(hash) < 20
  catch
    _ -> true
  end

  @spec blocked?(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: boolean()
  def blocked?(hash, ip, port) do
    blocked?(hash, ip, port, System.monotonic_time(:millisecond))
  catch
    :exit, _ -> false
  end

  defp blocked?(hash, ip, port, now) do
    case :ets.lookup(@table, key(hash, ip, port)) do
      [{_, until}] when is_integer(until) -> now < until
      _ -> false
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, hash, ip, port, ttl_ms}, state) do
    until = System.monotonic_time(:millisecond) + ttl_ms
    true = :ets.insert(@table, {key(hash, ip, port), until})
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_ms)
  end

  defp key(hash, ip, port), do: {hash, ip, port}
end

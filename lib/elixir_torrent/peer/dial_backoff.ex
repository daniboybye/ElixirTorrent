defmodule Peer.DialBackoff do
  @moduledoc false

  use GenServer

  require Logger

  @table :peer_dial_backoff
  @default_ttl_ms 5 * 60 * 1_000
  @timeout_ttl_ms 2 * 60 * 1_000
  @under_target_timeout_ttl_ms 45 * 1_000
  @hard_failure_ttl_ms 15 * 60 * 1_000
  # A peer that connects then immediately drops is churn — space out re-dials
  # regardless of how few peers we have (the under-target cap would let the loop
  # continue every 45s), but don't write it off for the session like a hard fail.
  @churn_ttl_ms 5 * 60 * 1_000
  @sweep_ms 60_000

  # A refused or unreachable host is a *hard* rejection: it won't start
  # accepting us on a quick retry the way a transient timeout might. These are
  # backed off long and are NOT subject to the aggressive under-target cap, so
  # we stop re-dialing dead endpoints every 45s and free the slot for fresh peers.
  @hard_failures [:econnrefused, :ehostunreach, :enetunreach, :eafnosupport]

  # "Sticky" blocks are never re-added to satisfy min_count when we're under the
  # peer target — otherwise the aggressive peer-finding path resurrects the very
  # dead/churning endpoints we just blocked, reviving the reconnect loop. Only
  # transient (timeout/closed) blocks may be re-added under target.
  @sticky_reasons [:churn | @hard_failures]

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

    # Sticky blocks (churn / hard failures) stay blocked even under target.
    soft_blocked =
      Enum.reject(blocked, fn %Peer{ip: ip, port: port} ->
        sticky_blocked?(hash, ip, port, now)
      end)

    if min_count <= 0 or length(allowed) >= min_count or soft_blocked == [] do
      allowed
    else
      need = min(min_count - length(allowed), length(soft_blocked))
      allowed ++ take_blocked_for_min_count(soft_blocked, allowed, need)
    end
  catch
    :exit, _ -> peers
  end

  @expected_dial_failures [:timeout, :closed, :econnrefused, :ehostunreach, :enetunreach, :handshake_timeout, :churn]

  @spec record(Torrent.hash(), :inet.ip_address(), :inet.port_number(), term()) :: :ok
  def record(hash, ip, port, reason) do
    level = if reason in @expected_dial_failures, do: :debug, else: :info

    Logger.log(
      level,
      "[peer_dial] fail endpoint=#{inspect(ip)}:#{port} reason=#{inspect(reason)} hash=#{Torrent.hex_encoded_hash(hash)}"
    )

    ttl = ttl_for(hash, reason)
    GenServer.cast(__MODULE__, {:record, hash, ip, port, ttl, reason in @sticky_reasons})
  catch
    :exit, _ -> :ok
  end

  defp ttl_for(_hash, reason) when reason in @hard_failures, do: @hard_failure_ttl_ms
  defp ttl_for(_hash, :churn), do: @churn_ttl_ms

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
      [{_, until, _sticky}] when is_integer(until) -> now < until
      _ -> false
    end
  end

  defp sticky_blocked?(hash, ip, port, now) do
    case :ets.lookup(@table, key(hash, ip, port)) do
      [{_, until, true}] when is_integer(until) -> now < until
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
  def handle_cast({:record, hash, ip, port, ttl_ms, sticky?}, state) do
    until = System.monotonic_time(:millisecond) + ttl_ms
    true = :ets.insert(@table, {key(hash, ip, port), until, sticky?})
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$2", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_ms)
  end

  defp key(hash, ip, port), do: {hash, ip, port}

  @spec take_blocked_for_min_count([Peer.t()], [Peer.t()], non_neg_integer()) :: [Peer.t()]
  defp take_blocked_for_min_count(_blocked, _allowed, 0), do: []

  defp take_blocked_for_min_count(blocked, allowed, need) do
    families =
      allowed
      |> Enum.map(&peer_family/1)
      |> MapSet.new()

    {same_family, other} =
      Enum.split_with(blocked, fn peer -> MapSet.member?(families, peer_family(peer)) end)

    same_family
    |> Enum.take(need)
    |> then(fn taken ->
      rest = need - length(taken)

      if rest > 0 do
        taken ++ Enum.take(other, rest)
      else
        taken
      end
    end)
  end

  @spec peer_family(Peer.t()) :: :inet | :inet6
  defp peer_family(%Peer{ip: ip}) do
    case tuple_size(ip) do
      4 -> :inet
      8 -> :inet6
      _ -> :inet
    end
  end
end

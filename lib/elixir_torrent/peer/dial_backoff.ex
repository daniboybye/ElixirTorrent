defmodule Peer.DialBackoff do
  @moduledoc false

  use GenServer

  require Logger

  @table :peer_dial_backoff
  @productive_table :peer_dial_productive
  @default_ttl_ms 5 * 60 * 1_000
  @timeout_ttl_ms 2 * 60 * 1_000
  @under_target_timeout_ttl_ms 45 * 1_000
  @hard_failure_ttl_ms 15 * 60 * 1_000
  # A peer that connects then immediately drops is churn — space out re-dials
  # regardless of how few peers we have (the under-target cap would let the loop
  # continue every 45s), but don't write it off for the session like a hard fail.
  @churn_ttl_ms 5 * 60 * 1_000
  # Micro-swarm: an endpoint that already delivered blocks is scarce. Transient
  # CGNAT timeouts must not escalate it to a 15min sticky write-off.
  @productive_timeout_ttl_ms 10_000
  @productive_mark_ttl_ms 60 * 60 * 1_000
  @sweep_ms 60_000

  # After this many recorded failures on the same endpoint, treat it as a hard
  # fail regardless of the underlying reason. Under CGNAT ~99% of v4 candidates
  # are dead-with-timeout; the old 2min transient TTL cycled them back into the
  # dial batch every couple minutes for the whole session. N=3 keeps a genuine
  # transient flap re-dialable but writes off endpoints that fail repeatedly.
  # Productive endpoints skip this escalation (see escalate/4).
  @hard_fail_threshold 3
  # Escalated block after crossing the threshold. Same TTL as an explicit hard
  # failure — we want these endpoints out of the batch for a long time.
  @escalated_ttl_ms @hard_failure_ttl_ms

  # Keep the fail_count around after the block expires so a subsequent re-dial
  # can see it and escalate. Must be > @default_ttl_ms so the counter survives
  # a normal transient block. When retention expires, the whole row is swept.
  @fail_count_retention_ms 30 * 60 * 1_000
  # Hard cap on ETS rows — under heavy dial churn the table grows ~2k/30min today;
  # evict the oldest retention_until rows when we exceed this ceiling so memory
  # stays bounded on long sessions without weakening active blocks.
  @default_max_rows 10_000

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

  # These outcomes don't reflect endpoint reachability — don't count them toward
  # the fail threshold and don't write a block row. :socket_handoff_failed means
  # connect+handshake succeeded and only local handoff failed; Endpoints already
  # records :churn when registration happened, so DialBackoff must not double-block.
  @non_reachability_reasons [:already_connected, :not_connectable, :socket_handoff_failed]

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

    # Sticky blocks (churn / hard failures / escalated) stay blocked even under target.
    soft_blocked =
      Enum.reject(blocked, fn %Peer{ip: ip, port: port} ->
        sticky_blocked?(hash, ip, port, now)
      end)

    if min_count <= 0 or length(allowed) >= min_count or soft_blocked == [] do
      allowed
    else
      need = min(min_count - length(allowed), length(soft_blocked))
      allowed ++ take_blocked_for_min_count(soft_blocked, hash, need)
    end
  catch
    :exit, _ -> peers
  end

  @doc """
  Remember that this endpoint delivered piece bytes. Softens future dial backoff
  (no sticky escalate on timeouts) and prioritizes re-dial after disconnect.
  """
  @spec mark_productive(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: :ok
  def mark_productive(hash, ip, port) do
    GenServer.cast(__MODULE__, {:mark_productive, hash, ip, port})
  catch
    :exit, _ -> :ok
  end

  @spec productive?(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: boolean()
  def productive?(hash, ip, port) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@productive_table, key(hash, ip, port)) do
      [{_, until}] when is_integer(until) and now < until -> true
      _ -> false
    end
  catch
    :exit, _ -> false
    :error, _ -> false
  end

  @expected_dial_failures [
    :timeout,
    :closed,
    :econnrefused,
    :ehostunreach,
    :enetunreach,
    :handshake_timeout,
    :churn
  ]

  @spec record(Torrent.hash(), :inet.ip_address(), :inet.port_number(), term()) :: :ok
  def record(hash, ip, port, reason) do
    if reason in @non_reachability_reasons do
      :ok
    else
      level = if reason in @expected_dial_failures, do: :debug, else: :info

      Logger.log(
        level,
        "[peer_dial] fail endpoint=#{inspect(ip)}:#{port} reason=#{inspect(reason)} hash=#{Torrent.hex_encoded_hash(hash)}"
      )

      ttl = ttl_for(hash, ip, port, reason)
      GenServer.cast(__MODULE__, {:record, hash, ip, port, ttl, reason})
    end
  catch
    :exit, _ -> :ok
  end

  defp ttl_for(_hash, _ip, _port, reason) when reason in @hard_failures, do: @hard_failure_ttl_ms
  defp ttl_for(_hash, _ip, _port, :churn), do: @churn_ttl_ms

  defp ttl_for(hash, ip, port, reason) do
    if productive?(hash, ip, port) and reason in [:timeout, :closed, :handshake_timeout] do
      @productive_timeout_ttl_ms
    else
      base =
        case reason do
          :timeout -> @timeout_ttl_ms
          :closed -> @timeout_ttl_ms
          _ -> @default_ttl_ms
        end

      if under_target?(hash), do: min(base, @under_target_timeout_ttl_ms), else: base
    end
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
      [{_, blocked_until, _retention, _sticky, _fail_count}] when is_integer(blocked_until) ->
        now < blocked_until

      _ ->
        false
    end
  end

  defp sticky_blocked?(hash, ip, port, now) do
    case :ets.lookup(@table, key(hash, ip, port)) do
      [{_, blocked_until, _retention, true, _fail_count}] when is_integer(blocked_until) ->
        now < blocked_until

      _ ->
        false
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@productive_table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{max_rows: max_rows()}}
  end

  @impl true
  def handle_cast({:mark_productive, hash, ip, port}, state) do
    now = System.monotonic_time(:millisecond)
    key = key(hash, ip, port)
    true = :ets.insert(@productive_table, {key, now + @productive_mark_ttl_ms})
    # Drop any active backoff so ConnectionManager can re-dial immediately —
    # a peer that just gave us blocks is worth another SYN, not a 45s park.
    :ets.delete(@table, key)
    {:noreply, state}
  end

  def handle_cast({:record, hash, ip, port, ttl_ms, reason}, state) do
    now = System.monotonic_time(:millisecond)
    key = key(hash, ip, port)
    productive? = productive_at?(key, now)

    prev_fail_count =
      case :ets.lookup(@table, key) do
        [{_, _, _, _, n}] when is_integer(n) -> n
        _ -> 0
      end

    fail_count = prev_fail_count + 1
    {final_ttl, sticky?} = escalate(reason, fail_count, ttl_ms, productive?)
    blocked_until = now + final_ttl
    retention_until = max(blocked_until, now + @fail_count_retention_ms)

    true = :ets.insert(@table, {key, blocked_until, retention_until, sticky?, fail_count})
    maybe_evict_oldest(state)

    if sticky? and fail_count == @hard_fail_threshold and reason not in @sticky_reasons do
      # Log the moment we escalate a transient endpoint — useful for confirming
      # the throttle is actually kicking in on the CGNAT hosts we care about.
      Logger.debug(
        "[peer_dial] escalated endpoint=#{inspect(ip)}:#{port} fail_count=#{fail_count} reason=#{inspect(reason)}"
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    # Sweep by retention_until (the 3rd tuple element), not blocked_until — the
    # fail_count needs to outlive the block so the next re-dial can escalate.
    :ets.select_delete(@table, [
      {{:"$1", :"$2", :"$3", :"$4", :"$5"}, [{:<, :"$3", now}], [true]}
    ])

    :ets.select_delete(@productive_table, [
      {{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_ms)
  end

  defp maybe_evict_oldest(%{max_rows: max_rows}) do
    size = :ets.info(@table, :size)

    if is_integer(size) and size > max_rows do
      drop = size - max_rows

      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_, _, retention, _, _} -> retention end)
      |> Enum.take(drop)
      |> Enum.each(fn {key, _, _, _, _} -> :ets.delete(@table, key) end)
    end
  end

  defp max_rows do
    Application.get_env(:elixir_torrent, :dial_backoff_max_rows, @default_max_rows)
  end

  defp key(hash, ip, port), do: {hash, ip, port}

  # Escalation policy — the single place that decides both TTL and stickiness
  # for a recorded failure.
  #
  #   * Reason is already hard/churn        → keep its TTL and mark sticky.
  #   * Productive endpoint + transient     → never sticky-escalate (micro-swarm
  #                                            known-good peers flap under CGNAT).
  #   * fail_count reached the threshold    → escalated TTL + sticky, regardless
  #                                            of the immediate reason. This is
  #                                            the "N transient timeouts = dead
  #                                            endpoint" case that motivated
  #                                            this whole extension.
  #   * Otherwise                           → the caller-computed TTL, soft.
  defp escalate(reason, _fail_count, ttl_ms, _productive?) when reason in @sticky_reasons do
    {ttl_ms, true}
  end

  defp escalate(reason, _fail_count, ttl_ms, true)
       when reason in [:timeout, :closed, :handshake_timeout] do
    {ttl_ms, false}
  end

  defp escalate(_reason, fail_count, _ttl_ms, false) when fail_count >= @hard_fail_threshold do
    {@escalated_ttl_ms, true}
  end

  defp escalate(_reason, _fail_count, ttl_ms, _productive?), do: {ttl_ms, false}

  defp productive_at?(key, now) do
    case :ets.lookup(@productive_table, key) do
      [{_, until}] when is_integer(until) and now < until -> true
      _ -> false
    end
  end

  # When min_count pressure resurrects soft-blocked peers: productive first
  # (known byte-deliverers), then v6 before v4. Under CGNAT outbound v6 yield
  # is ~10–20× better than v4; matching a v4-heavy allowed slice would amplify
  # dead v4 candidates and drain the v6 dial budget.
  @spec take_blocked_for_min_count([Peer.t()], Torrent.hash(), non_neg_integer()) :: [Peer.t()]
  defp take_blocked_for_min_count(_blocked, _hash, 0), do: []

  defp take_blocked_for_min_count(blocked, hash, need) do
    {productive, rest} =
      Enum.split_with(blocked, fn %Peer{ip: ip, port: port} ->
        productive?(hash, ip, port)
      end)

    {v6, v4} = Enum.split_with(rest, fn peer -> peer_family(peer) == :inet6 end)

    productive
    |> Kernel.++(v6)
    |> Kernel.++(v4)
    |> Enum.take(need)
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

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
  # Escalation asks "is this endpoint dead", so it must count failures *close
  # together*, not failures ever. Retention is refreshed on every failure, so a
  # row re-dialled at least once per @fail_count_retention_ms never aged out and
  # its counter only climbed: live rows reached fail_count 107-109, which is a
  # permanent sticky block on an endpoint that merely fails intermittently.
  # Failures further apart than this start a fresh streak.
  @fail_streak_window_ms 10 * 60 * 1_000
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

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec filter([Peer.t()], Torrent.hash(), non_neg_integer()) :: [Peer.t()]
  def filter(peers, hash, min_count \\ 0) when is_list(peers) and is_integer(min_count) do
    now = System.monotonic_time(:millisecond)
    {allowed, blocked} = partition_by_block(peers, hash, now)
    apply_min_count_resurrection(allowed, blocked, hash, min_count)
  catch
    :exit, _ -> peers
  end

  @spec partition_by_block([Peer.t()], Torrent.hash(), integer()) :: {[Peer.t()], [Peer.t()]}
  defp partition_by_block(peers, hash, now) do
    Enum.split_with(peers, fn %Peer{ip: ip, port: port} ->
      not blocked?(hash, ip, port, now)
    end)
  end

  @spec apply_min_count_resurrection([Peer.t()], [Peer.t()], Torrent.hash(), non_neg_integer()) ::
          [Peer.t()]
  defp apply_min_count_resurrection(allowed, blocked, hash, min_count) do
    if min_count <= 0 or length(allowed) >= min_count or blocked == [] do
      allowed
    else
      need = min(min_count - length(allowed), length(blocked))
      allowed ++ take_blocked_for_min_count(blocked, hash, need)
    end
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

  @doc """
  Forget an endpoint's failure history — we have a live connection to it.

  This table answers "is this endpoint reachable", and a registered peer settles
  that question: TCP connect and the BEP 3 handshake both completed. Only
  `mark_productive/3` used to clear a row, which instead answers "was it useful",
  and the two come apart badly on a leecher with nothing to trade: peers keep us
  choked, so a reachable endpoint never delivers bytes and carries its failure
  history for the whole session. Live, 1151 of 1162 active blocks were sticky and
  every torrent was down to 3-8 dialable endpoints out of 37-53 known.
  """
  @spec record_success(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: :ok
  def record_success(hash, ip, port) do
    GenServer.cast(__MODULE__, {:record_success, hash, ip, port})
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
      [{_, blocked_until, _retention, _sticky, _fail_count, _last_at}]
      when is_integer(blocked_until) ->
        now < blocked_until

      _ ->
        false
    end
  end

  defp sticky_blocked?(hash, ip, port, now) do
    case :ets.lookup(@table, key(hash, ip, port)) do
      [{_, blocked_until, _retention, true, _fail_count, _last_at}]
      when is_integer(blocked_until) ->
        now < blocked_until

      _ ->
        false
    end
  end

  @spec fail_count(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: non_neg_integer()
  defp fail_count(hash, ip, port) do
    case :ets.lookup(@table, key(hash, ip, port)) do
      [{_, _, _, _, n, _}] when is_integer(n) -> n
      _ -> 0
    end
  end

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@productive_table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{max_rows: max_rows()}}
  end

  @impl GenServer
  def handle_cast({:mark_productive, hash, ip, port}, state) do
    now = System.monotonic_time(:millisecond)
    key = key(hash, ip, port)
    true = :ets.insert(@productive_table, {key, now + @productive_mark_ttl_ms})
    # Drop any active backoff so ConnectionManager can re-dial immediately —
    # a peer that just gave us blocks is worth another SYN, not a 45s park.
    :ets.delete(@table, key)
    {:noreply, state}
  end

  def handle_cast({:record_success, hash, ip, port}, state) do
    :ets.delete(@table, key(hash, ip, port))
    {:noreply, state}
  end

  def handle_cast({:record, hash, ip, port, ttl_ms, reason}, state) do
    now = System.monotonic_time(:millisecond)
    key = key(hash, ip, port)
    {sticky?, fail_count} = insert_failure_record(key, ip, port, ttl_ms, reason, now)
    maybe_evict_oldest(state)
    maybe_log_escalation(sticky?, fail_count, reason, ip, port)
    {:noreply, state}
  end

  @spec insert_failure_record(
          term(),
          :inet.ip_address(),
          :inet.port_number(),
          pos_integer(),
          term(),
          integer()
        ) :: {boolean(), pos_integer()}
  defp insert_failure_record(key, _ip, _port, ttl_ms, reason, now) do
    productive? = productive_at?(key, now)
    fail_count = streak_count(key, now) + 1
    {final_ttl, sticky?} = escalate(reason, fail_count, ttl_ms, productive?)
    blocked_until = now + final_ttl
    retention_until = max(blocked_until, now + @fail_count_retention_ms)

    true = :ets.insert(@table, {key, blocked_until, retention_until, sticky?, fail_count, now})
    {sticky?, fail_count}
  end

  # Failures more than @fail_streak_window_ms apart are separate incidents, not
  # mounting evidence that the endpoint is dead.
  @spec streak_count(term(), integer()) :: non_neg_integer()
  defp streak_count(key, now) do
    case :ets.lookup(@table, key) do
      [{_, _, _, _, n, last_at}]
      when is_integer(n) and is_integer(last_at) and now - last_at <= @fail_streak_window_ms ->
        n

      _ ->
        0
    end
  end

  @spec maybe_log_escalation(
          boolean(),
          pos_integer(),
          term(),
          :inet.ip_address(),
          :inet.port_number()
        ) ::
          :ok
  defp maybe_log_escalation(sticky?, fail_count, reason, ip, port) do
    if sticky? and fail_count == @hard_fail_threshold and reason not in @sticky_reasons do
      # Log the moment we escalate a transient endpoint — useful for confirming
      # the throttle is actually kicking in on the CGNAT hosts we care about.
      Logger.debug(
        "[peer_dial] escalated endpoint=#{inspect(ip)}:#{port} fail_count=#{fail_count} reason=#{inspect(reason)}"
      )
    else
      :ok
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    # Sweep by retention_until (the 3rd tuple element), not blocked_until — the
    # fail_count needs to outlive the block so the next re-dial can escalate.
    :ets.select_delete(@table, [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6"}, [{:<, :"$3", now}], [true]}
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
      |> Enum.sort_by(fn {_, _, retention, _, _, _} -> retention end)
      |> Enum.take(drop)
      |> Enum.each(fn {key, _, _, _, _, _} -> :ets.delete(@table, key) end)
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

  # Priority when min_count pressure makes us re-dial blocked endpoints:
  #
  #   1. productive — it already delivered bytes to us, so it is scarce and proven
  #   2. soft-blocked before sticky — sticky means we deliberately wrote it off
  #   3. v6 before v4 — outbound v6 yield here is ~10-20× v4 under CGNAT, so a
  #      v4-heavy slice would burn the batch on timeouts
  #   4. fewest failures first — least evidence against it
  #
  # Sticky used to be excluded outright, which is right while anything else is
  # dialable and starves the torrent once nothing is. Every block a CGNAT host
  # records is sticky in practice — churn, hard failures and the escalated
  # write-off all are — so live 1151 of 1162 active blocks refused resurrection,
  # leaving eight of nine torrents asking for a 50-endpoint batch and getting
  # 3-8, with the scarce v6 pool blocked 2-6 of 5-8. A SYN to a written-off
  # endpoint costs one timeout; not dialling costs the torrent.
  @spec take_blocked_for_min_count([Peer.t()], Torrent.hash(), non_neg_integer()) :: [Peer.t()]
  defp take_blocked_for_min_count(_blocked, _hash, 0), do: []

  defp take_blocked_for_min_count(blocked, hash, need) do
    now = System.monotonic_time(:millisecond)

    blocked
    |> Enum.sort_by(fn %Peer{ip: ip, port: port} = peer ->
      {
        if(productive?(hash, ip, port), do: 0, else: 1),
        if(sticky_blocked?(hash, ip, port, now), do: 1, else: 0),
        if(peer_family(peer) == :inet6, do: 0, else: 1),
        fail_count(hash, ip, port)
      }
    end)
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

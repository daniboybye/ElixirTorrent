defmodule Peer.DialStats do
  @moduledoc false

  # Tracks a per-torrent, per-family (IPv4/IPv6) rolling count of recent outbound
  # dial outcomes so the dial batcher can stop burning the whole batch on a family
  # whose connects are timing out ~100% of the time.
  #
  # Networking rationale (why per-family reachability differs):
  # Whether an *outbound* dial to a peer succeeds depends on both ends. Under
  # CGNAT this host has no inbound IPv4 and its outbound v4 dials mostly land on
  # peers that are themselves behind NAT with no open v4 port — so v4 connects
  # time out almost always (measured here: ~1.3% success over 1200+ attempts). The
  # same host has a *global* IPv6 address, and peers advertising global v6 tend to
  # be directly reachable — so v6 connects succeed far more often (measured ~25%).
  # On a different host (native dual-stack, or v6-less) the dead family could just
  # as easily be v6. So "which family is worth dialing" is not a constant — it has
  # to be *measured per family, per torrent* and re-checked as the network changes.
  #
  # This module answers exactly that question — "is outbound dialing of family F
  # for THIS torrent currently proven wasteful?" — from observed success rate, via
  # `throttle_worthy?/2`. The batcher (Acceptor.Connection.Handshakes) combines
  # that judgment with the queue's composition: it throttles a wasteful family only
  # when the *other* family is a viable alternative, never starves a sole family,
  # and always keeps a tiny probe of the throttled family so a recovery (network
  # change, roaming onto a better path) lifts the throttle on its own. This is
  # outbound-dial policy only; it never touches the inbound listener.

  use GenServer

  @table :peer_dial_stats

  # Minimum recent attempts (of one family, for one torrent) before we trust the
  # measured success rate enough to act on it. ~one batch worth, so a couple of
  # unlucky dials never trip it.
  @min_sample 12

  # A family whose success rate is at or below this is treated as "proven
  # wasteful". Expressed as an integer fraction to keep the comparison in integer
  # math. 3% is chosen from live data: this CGNAT host measured IPv4 at 1.3%
  # (throttle) but IPv6 at 25% (keep) — 3% cleanly separates the two while staying
  # conservative, so a family has to be genuinely dead (not merely unlucky) before
  # we back off. At @min_sample this reduces to "zero successes"; the small epsilon
  # only starts to matter once the sample is large (34+ attempts), which is exactly
  # the regime where a persistent 1-2% trickle is still effectively dead.
  @throttle_rate_num 3
  @throttle_rate_den 100

  # When v6's measured success rate is at least this many times v4's, the dial
  # batcher may bias toward v6 outside the critical tier (still keeps a v4 probe).
  @prefer_ratio_num 2
  @prefer_ratio_den 1

  # Counts decay toward zero so the rate reflects the last several minutes and both
  # stale successes and stale failures age out. We decay *gently* — multiply by
  # @decay_num/@decay_den (7/8) each minute, a ~5 min half-life — rather than the
  # old hard halving every 2 min. The hard halving was the source of a flap: a
  # family sitting just over @min_sample (say 13 attempts) dropped to ~6 in a
  # single tick, fell under the sample gate, un-throttled for a full batch of dead
  # dials, then the next batch pushed it back over the gate and re-throttled it — a
  # ~2 minute on/off cycle. A gentle per-minute step can't cross the gate in one
  # tick, so under active dialing the sample gate is stable while genuinely old
  # data still ages out within tens of minutes of inactivity.
  @decay_ms 60_000
  @decay_num 7
  @decay_den 8

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record the aggregate outcome of a batch of same-family dials.

  `ok` and `fail` measure whether the address family reached and completed the
  BitTorrent handshake. Callers exclude neutral outcomes (`:already_connected`,
  `:not_connectable`) and count post-handshake local handoff failures as `ok`,
  so OTP ownership churn cannot depress a family's measured network yield.
  """
  @spec record(Torrent.hash(), :inet | :inet6, non_neg_integer(), non_neg_integer()) :: :ok
  def record(_hash, _family, 0, 0), do: :ok

  def record(hash, family, ok, fail)
      when is_integer(ok) and ok >= 0 and is_integer(fail) and fail >= 0 do
    _ =
      :ets.update_counter(
        @table,
        key(hash, family),
        [{2, ok}, {3, fail}],
        {key(hash, family), 0, 0}
      )

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Is outbound dialing of `family` for this torrent currently proven wasteful?

  True only when there is a real, recent sample of attempts (`>= @min_sample`)
  whose measured success rate is at or below `@throttle_rate_num/@throttle_rate_den`
  (a few percent). This is the per-family half of the throttle decision; the
  batcher additionally requires a *viable other family* before it acts, so a sole
  (v4-only or v6-only) swarm is never starved even when it reads as wasteful.

  Config-gated: returns `false` when the feature is disabled (see `enabled?/0`), so
  the whole throttle can be turned off without touching the batcher.
  """
  @spec throttle_worthy?(Torrent.hash(), :inet | :inet6) :: boolean()
  def throttle_worthy?(hash, family) when family in [:inet, :inet6] do
    enabled?() and wasteful_rate?(counts(hash, family))
  end

  @doc """
  Is IPv6 outbound clearly outperforming IPv4 for this torrent?

  True when both families have a meaningful recent sample (`>= @min_sample`)
  and v6's measured success rate is at least `@prefer_ratio_num`× v4's. The
  batcher uses this outside the critical tier to fill ~75% v6 / ~25% v4 instead
  of a family-neutral 50/50 split — without starving v4 entirely (it still gets
  at least a probe-sized slice). Config-gated like `throttle_worthy?/2`.
  """
  @spec prefer_inet6?(Torrent.hash()) :: boolean()
  def prefer_inet6?(hash) do
    enabled?() and prefer_inet6_rate?(counts(hash, :inet), counts(hash, :inet6))
  end

  # Integer form of `rate_v6 >= @prefer_ratio * rate_v4` with both totals >= @min_sample.
  @spec prefer_inet6_rate?(
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) ::
          boolean()
  defp prefer_inet6_rate?({ok4, fail4}, {ok6, fail6}) do
    total4 = ok4 + fail4
    total6 = ok6 + fail6

    total4 >= @min_sample and total6 >= @min_sample and
      ok6 * total4 * @prefer_ratio_den >= @prefer_ratio_num * ok4 * total6
  end

  # Integer form of `total >= @min_sample and ok / total <= @throttle_rate`.
  @spec wasteful_rate?({non_neg_integer(), non_neg_integer()}) :: boolean()
  defp wasteful_rate?({ok, fail}) do
    total = ok + fail
    total >= @min_sample and ok * @throttle_rate_den <= @throttle_rate_num * total
  end

  @doc false
  @spec counts(Torrent.hash(), :inet | :inet6) :: {non_neg_integer(), non_neg_integer()}
  def counts(hash, family) do
    case :ets.lookup(@table, key(hash, family)) do
      [{_, ok, fail}] -> {ok, fail}
      _ -> {0, 0}
    end
  rescue
    ArgumentError -> {0, 0}
  end

  # Config gate. `:dial_family_cap` is the canonical switch; `:v6_dial_cap` is the
  # old name kept for backward compatibility (a node that set it to `false` to turn
  # the feature off keeps working). Defaults on.
  defp enabled? do
    case Application.get_env(:elixir_torrent, :dial_family_cap) do
      nil -> Application.get_env(:elixir_torrent, :v6_dial_cap, true)
      value -> value
    end
  end

  @impl GenServer
  def init(_) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_decay()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:decay, state) do
    # Gently age every counter; drop rows that have fully aged out so the table
    # stays bounded to torrents with genuinely recent dial activity.
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, ok, fail} ->
      ok = div(ok * @decay_num, @decay_den)
      fail = div(fail * @decay_num, @decay_den)

      if ok == 0 and fail == 0 do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, ok, fail})
      end
    end)

    schedule_decay()
    {:noreply, state}
  end

  defp schedule_decay, do: Process.send_after(self(), :decay, @decay_ms)

  defp key(hash, family), do: {hash, family}
end

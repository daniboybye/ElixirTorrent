defmodule Peer.DialBackoffTest do
  use ExUnit.Case, async: false

  alias Peer.DialBackoff

  @hash :binary.copy(<<0xEE>>, 20)

  defp peer(d, port), do: %Peer{ip: {10, 0, 0, d}, port: port}
  defp peer6(n, port), do: %Peer{ip: {0x2001, 0xDB8, 0, 0, 0, 0, 0, n}, port: port}

  setup do
    # DialBackoff is a singleton GenServer started with the app; clear its tables.
    if :ets.info(:peer_dial_backoff) != :undefined, do: :ets.delete_all_objects(:peer_dial_backoff)

    if :ets.info(:peer_dial_productive) != :undefined,
      do: :ets.delete_all_objects(:peer_dial_productive)

    :ok
  end

  test "a transient (timeout) block is re-added under target to meet min_count" do
    p = peer(1, 6881)
    DialBackoff.record(@hash, p.ip, p.port, :timeout)
    # cast is async; let it land
    _ = :sys.get_state(DialBackoff)

    # min_count forces re-inclusion of the soft-blocked peer when nothing else is available.
    assert DialBackoff.filter([p], @hash, 1) == [p]
    # ...but with no min pressure it stays filtered out.
    assert DialBackoff.filter([p], @hash, 0) == []
  end

  test "a churn block is NOT re-added even under min_count pressure" do
    p = peer(2, 6882)
    DialBackoff.record(@hash, p.ip, p.port, :churn)
    _ = :sys.get_state(DialBackoff)

    assert DialBackoff.filter([p], @hash, 5) == []
    assert DialBackoff.filter([p], @hash, 0) == []
  end

  test "a hard-failure block is sticky too" do
    p = peer(3, 6883)
    DialBackoff.record(@hash, p.ip, p.port, :econnrefused)
    _ = :sys.get_state(DialBackoff)

    assert DialBackoff.filter([p], @hash, 5) == []
  end

  test "unblocked peers always pass through" do
    p = peer(4, 6884)
    assert DialBackoff.filter([p], @hash, 0) == [p]
    assert DialBackoff.filter([p], @hash, 5) == [p]
  end

  test "N transient failures escalate the endpoint to sticky-blocked" do
    p = peer(5, 6885)

    # A single :timeout is transient — soft-blocked, still re-addable under
    # min_count pressure.
    DialBackoff.record(@hash, p.ip, p.port, :timeout)
    _ = :sys.get_state(DialBackoff)
    assert DialBackoff.filter([p], @hash, 5) == [p]

    # The 2nd :timeout — still under the escalation threshold.
    DialBackoff.record(@hash, p.ip, p.port, :timeout)
    _ = :sys.get_state(DialBackoff)
    assert DialBackoff.filter([p], @hash, 5) == [p]

    # The 3rd :timeout crosses @hard_fail_threshold and promotes the row to
    # sticky. It must now be excluded even under aggressive min_count pressure.
    DialBackoff.record(@hash, p.ip, p.port, :timeout)
    _ = :sys.get_state(DialBackoff)
    assert DialBackoff.filter([p], @hash, 5) == []
    assert DialBackoff.filter([p], @hash, 0) == []
  end

  test "non-reachability outcomes (already_connected / not_connectable) do not accumulate" do
    p = peer(6, 6886)

    # Many :already_connected records — these are not reachability signals and
    # must not accumulate toward the escalation threshold.
    for _ <- 1..10 do
      DialBackoff.record(@hash, p.ip, p.port, :already_connected)
    end

    _ = :sys.get_state(DialBackoff)
    assert DialBackoff.filter([p], @hash, 0) == [p]
  end

  test "socket_handoff_failed does not write a backoff row (endpoint was reachable; churn handled elsewhere)" do
    p = peer(7, 6887)

    for _ <- 1..10 do
      DialBackoff.record(@hash, p.ip, p.port, :socket_handoff_failed)
    end

    _ = :sys.get_state(DialBackoff)
    assert DialBackoff.filter([p], @hash, 0) == [p]
    refute DialBackoff.blocked?(@hash, p.ip, p.port)
  end

  test "genuine handshake failures still block the endpoint" do
    p = peer(8, 6888)
    DialBackoff.record(@hash, p.ip, p.port, :handshake_timeout)
    _ = :sys.get_state(DialBackoff)

    assert DialBackoff.filter([p], @hash, 0) == []
  end

  test "min_count resurrection prefers soft-blocked v6 over v4 when allowed is mostly v4" do
    allowed_v4_a = peer(10, 6890)
    allowed_v4_b = peer(11, 6891)
    blocked_v4 = peer(12, 6892)
    blocked_v6_a = peer6(1, 6893)
    blocked_v6_b = peer6(2, 6894)

    for p <- [blocked_v4, blocked_v6_a, blocked_v6_b] do
      DialBackoff.record(@hash, p.ip, p.port, :timeout)
    end

    _ = :sys.get_state(DialBackoff)

    peers = [allowed_v4_a, allowed_v4_b, blocked_v4, blocked_v6_a, blocked_v6_b]

    # Two allowed v4 + need three fillers → v6 soft-blocked first, then v4.
    assert DialBackoff.filter(peers, @hash, 5) ==
             [allowed_v4_a, allowed_v4_b, blocked_v6_a, blocked_v6_b, blocked_v4]
  end

  test "evicts oldest rows when the table exceeds @max_rows" do
    :sys.replace_state(DialBackoff, fn state -> Map.put(state, :max_rows, 50) end)

    for n <- 1..55 do
      DialBackoff.record(@hash, {10, 0, 0, rem(n, 250) + 1}, 6000 + n, :timeout)
    end

    _ = :sys.get_state(DialBackoff)
    assert :ets.info(:peer_dial_backoff, :size) == 50
  end

  test "mark_productive clears an active block so the endpoint is dialable again" do
    p = peer(20, 7001)
    DialBackoff.record(@hash, p.ip, p.port, :timeout)
    _ = :sys.get_state(DialBackoff)
    assert DialBackoff.filter([p], @hash, 0) == []

    DialBackoff.mark_productive(@hash, p.ip, p.port)
    _ = :sys.get_state(DialBackoff)

    assert DialBackoff.productive?(@hash, p.ip, p.port)
    assert DialBackoff.filter([p], @hash, 0) == [p]
  end

  test "productive endpoints do not sticky-escalate after N transient timeouts" do
    p = peer(21, 7002)
    DialBackoff.mark_productive(@hash, p.ip, p.port)
    _ = :sys.get_state(DialBackoff)

    for _ <- 1..5 do
      DialBackoff.record(@hash, p.ip, p.port, :timeout)
    end

    _ = :sys.get_state(DialBackoff)

    # Still soft-blocked (short TTL) under min_count, never sticky-written-off.
    assert DialBackoff.filter([p], @hash, 5) == [p]
  end

  test "min_count resurrection prefers productive soft-blocked peers before family order" do
    productive_v4 = peer(30, 7010)
    blocked_v6 = peer6(9, 7011)

    DialBackoff.mark_productive(@hash, productive_v4.ip, productive_v4.port)
    DialBackoff.record(@hash, productive_v4.ip, productive_v4.port, :timeout)
    DialBackoff.record(@hash, blocked_v6.ip, blocked_v6.port, :timeout)
    _ = :sys.get_state(DialBackoff)

    assert DialBackoff.filter([productive_v4, blocked_v6], @hash, 1) == [productive_v4]
  end
end

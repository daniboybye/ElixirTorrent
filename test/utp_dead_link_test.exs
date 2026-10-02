defmodule UTPDeadLinkTest do
  # A uTP peer that vanished (client closed, CGNAT mapping expired/rebound) is
  # invisible to us: UDP has no connection state, so the only signal is our own
  # retransmission timer. These tests pin the bound on how long such a dead
  # link may hold a peer slot, and - just as important - that a lossy or
  # high-RTT link that still answers occasionally is NOT mistaken for a dead one.
  #
  # Deterministic by construction: time is "advanced" by backdating the unacked
  # packets' send timestamps / the silent-streak start in isolated state and then
  # injecting the exact :tick message (TESTING.md "Timer tests" rule 1). No
  # sleeps; the real process test waits on the actual {:utp_closed, _} message
  # and process DOWN.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UTP.{Connection, Dispatcher, LEDBAT, Packet}

  @ip {127, 0, 0, 1}
  @recv_id 41_001
  @send_id 41_002
  @max_consecutive_timeouts 6

  setup do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end

    :ok = TestSupport.Sync.safe_resume(Dispatcher)

    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
    {:ok, {_ip, peer_port}} = :inet.sockname(peer_udp)

    on_exit(fn ->
      :gen_udp.close(udp)
      :gen_udp.close(peer_udp)
    end)

    {:ok, udp: udp, peer_udp: peer_udp, peer_port: peer_port}
  end

  describe "a silent peer" do
    test "is dropped after consecutive RTO expiries with nothing heard, reason :utp_timeout",
         ctx do
      state = connected_state(ctx)

      # Expiries 1..5: the connection keeps retransmitting (and backing off).
      state =
        Enum.reduce(1..(@max_consecutive_timeouts - 1), state, fn n, acc ->
          assert {:noreply, next} = Connection.handle_info(:tick, expire(acc))
          refute next.closed
          assert next.timeout_count == n
          assert next.activity.silent_since_ms != nil
          assert map_size(next.unacked) == 1
          next
        end)

      # Expiry 6: give up - clean shutdown, owner told so the peer process exits.
      log =
        capture_log(fn ->
          assert {:noreply, dead} = Connection.handle_info(:tick, expire(state))
          assert dead.closed
          assert dead.phase == :closed
        end)

      assert log =~ "reason=:utp_timeout"
      assert_received {:utp_closed, {:utp, _}}
    end

    test "a real connection process is torn down: owner notified, process exits", ctx do
      %{udp: udp, peer_udp: peer_udp, peer_port: peer_port} = ctx

      assert {:ok, {:utp, pid} = socket} =
               Connection.start_client(udp, @ip, peer_port, conn_id: 41_101)

      assert {:ok, {_ip, _port, _syn}} = :gen_udp.recv(peer_udp, 0, 1_000)
      send(pid, {:utp_packet, packet(Packet.st_state(), 41_101, 9_000, 1), <<>>, []})
      assert :ok = Connection.await_connected(socket, 1_000)
      assert {:ok, {_ip, _port, _handshake_ack}} = :gen_udp.recv(peer_udp, 0, 1_000)

      :ok = Connection.controlling_process(socket, self())
      mon = Process.monitor(pid)

      assert :ok = Connection.send_raw(socket, "payload the peer never acknowledges")
      assert {:ok, {_ip, _port, data_wire}} = :gen_udp.recv(peer_udp, 0, 1_000)
      assert {:ok, %{type: type}, _payload, _ext} = Packet.decode(data_wire)
      assert type == Packet.st_data()

      for _ <- 1..(@max_consecutive_timeouts - 1) do
        backdate_unacked(pid)
        send(pid, :tick)
        # Each expiry is a real retransmission on the wire.
        assert {:ok, {_ip, _port, retry_wire}} = :gen_udp.recv(peer_udp, 0, 1_000)
        assert {:ok, %{type: ^type}, _payload, _ext} = Packet.decode(retry_wire)
      end

      backdate_unacked(pid)
      send(pid, :tick)

      assert_receive {:utp_closed, ^socket}, 1_000
      # shutdown/2 lingers @linger_ms (1 s) before the GenServer stops.
      assert_receive {:DOWN, ^mon, :process, ^pid, :normal}, 2_500
    end

    test "is dropped by the wall-clock cap even between two long back-off expiries", ctx do
      now = System.monotonic_time(:millisecond)

      # One expiry already happened 61 s ago and the RTO has since backed off to
      # 60 s, so the *next* expiry is far away - the tick-level cap must fire
      # without waiting for it. The count (1) is nowhere near the count cap.
      state =
        connected_state(ctx,
          timeout_ms: 60_000,
          timeout_count: 1,
          silent_since_ms: now - 61_000,
          unacked: %{2 => {Packet.st_data(), <<"q">>, now, 2, 1}}
        )

      log =
        capture_log(fn ->
          assert {:noreply, dead} = Connection.handle_info(:tick, state)
          assert dead.closed
        end)

      assert log =~ "reason=:utp_timeout"
      assert_received {:utp_closed, {:utp, _}}
    end

    test "survives a silent streak that is still within both bounds", ctx do
      now = System.monotonic_time(:millisecond)

      state =
        connected_state(ctx,
          timeout_ms: 8_000,
          timeout_count: 3,
          silent_since_ms: now - 30_000,
          unacked: %{2 => {Packet.st_data(), <<"q">>, now, 4, 1}}
        )

      assert {:noreply, still} = Connection.handle_info(:tick, state)
      refute still.closed
      refute_received {:utp_closed, _}
    end
  end

  describe "a slow but alive link" do
    test "any inbound packet resets the consecutive-timeout streak", ctx do
      state =
        Enum.reduce(1..(@max_consecutive_timeouts - 1), connected_state(ctx), fn _, acc ->
          assert {:noreply, next} = Connection.handle_info(:tick, expire(acc))
          next
        end)

      # One expiry away from the give-up, then the peer speaks (a duplicate ACK
      # that frees nothing is enough: it still proves the path is alive).
      assert state.timeout_count == @max_consecutive_timeouts - 1
      assert {:noreply, heard} = inbound(state, packet(Packet.st_state(), @recv_id, 9_000, 0))
      assert heard.timeout_count == 0
      assert heard.activity.silent_since_ms == nil
      assert map_size(heard.unacked) == 1

      # A fresh streak starts from zero: five more expiries are survived again.
      # (Fresh packet: the per-packet tx_count >= 10 backstop is a separate rule.)
      survived =
        Enum.reduce(1..(@max_consecutive_timeouts - 1), fresh_packet(heard), fn n, acc ->
          assert {:noreply, next} = Connection.handle_info(:tick, expire(acc))
          refute next.closed
          assert next.timeout_count == n
          next
        end)

      refute survived.closed
      refute_received {:utp_closed, _}
    end

    test "a link that loses packets but answers between expiries lives indefinitely", ctx do
      final =
        Enum.reduce(1..40, connected_state(ctx), fn _round, acc ->
          assert {:noreply, expired} = Connection.handle_info(:tick, expire(acc))
          refute expired.closed
          assert expired.timeout_count == 1

          # The retransmission (tx_count 2) finally gets through and is ACKed.
          # Karn's rule means update_rtt ignores an ACK of a retransmitted
          # packet, so only the inbound-packet reset can clear the streak here -
          # which is the case a lossy link produces over and over.
          assert {:noreply, heard} =
                   inbound(expired, packet(Packet.st_state(), @recv_id, 9_000, 2))

          refute heard.closed
          assert heard.unacked == %{}
          assert heard.timeout_count == 0
          assert heard.activity.silent_since_ms == nil

          # ...and the sender queues the next packet.
          fresh_packet(heard)
        end)

      refute final.closed
      refute_received {:utp_closed, _}
    end
  end

  describe "an idle connection" do
    test "with nothing unacked is never timed out by the retransmission bounds", ctx do
      long_ago = System.monotonic_time(:millisecond) - 600_000

      # Healthy and quiet for 10 minutes (BitTorrent keep-alive is the peer's
      # business, not ours). Even a leftover streak marker from an earlier
      # hiccup must not kill it: there is no unacked data to be silent about.
      state =
        connected_state(ctx,
          unacked: %{},
          timeout_count: 3,
          silent_since_ms: long_ago,
          activity: %{last_send_ms: long_ago, last_recv_ms: long_ago, idle_probe_count: 0}
        )

      assert {:noreply, still} = Connection.handle_info(:tick, state)
      refute still.closed
      assert still.phase == :connected
      refute_received {:utp_closed, _}
    end
  end

  # --- helpers ------------------------------------------------------------

  defp connected_state(%{udp: udp, peer_port: peer_port}, overrides \\ []) do
    now = System.monotonic_time(:millisecond)

    defaults = [
      udp_socket: udp,
      peer_ip: @ip,
      peer_port: peer_port,
      owner: self(),
      socket_ref: {:utp, self()},
      role: :client,
      phase: :connected,
      recv_conn_id: @recv_id,
      send_conn_id: @send_id,
      seq_nr: 3,
      ack_nr: 1,
      recv_next: 2,
      timeout_ms: 500,
      led: LEDBAT.new(),
      unacked: %{2 => {Packet.st_data(), <<"q">>, now, 1, 1}},
      activity: %{last_send_ms: now, last_recv_ms: now, idle_probe_count: 0}
    ]

    # silent_since_ms lives inside `activity`; accept it as a convenience option.
    {silent_since_ms, overrides} = Keyword.pop(overrides, :silent_since_ms)
    state = struct!(Connection, Keyword.merge(defaults, overrides))

    if silent_since_ms,
      do: %{state | activity: Map.put(state.activity, :silent_since_ms, silent_since_ms)},
      else: state
  end

  # "Advance the clock" past the current RTO: backdate every unacked packet.
  defp expire(state) do
    old = System.monotonic_time(:millisecond) - 120_000

    %{
      state
      | unacked: Map.new(state.unacked, fn {seq, entry} -> {seq, put_sent_ms(entry, old)} end)
    }
  end

  # A newly sent (tx_count 1) data packet, as the sender would queue next.
  defp fresh_packet(state) do
    now = System.monotonic_time(:millisecond)
    %{state | unacked: %{2 => {Packet.st_data(), <<"q">>, now, 1, 1}}}
  end

  defp backdate_unacked(pid) do
    :sys.replace_state(pid, &expire/1)
  end

  defp put_sent_ms({type, payload, _sent_ms, tx_count, bytes}, sent_ms),
    do: {type, payload, sent_ms, tx_count, bytes}

  defp inbound(state, header), do: Connection.handle_info({:utp_packet, header, <<>>, []}, state)

  defp packet(type, conn_id, seq_nr, ack_nr) do
    %Packet{
      type: type,
      version: 1,
      extension: 0,
      conn_id: conn_id,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 65_536,
      seq_nr: seq_nr,
      ack_nr: ack_nr
    }
  end
end

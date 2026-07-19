defmodule UTPCorrectnessTest do
  # Regression tests for a batch of uTP off-spec behaviours diagnosed
  # 2026-07-17 and fixed 2026-07-18:
  #
  #   1. check_timeouts doubled `timeout_ms` for every timed-out packet in one
  #      reduce pass (libutp does one back-off per collision event).
  #   2. Fast retransmit only fired on the 4th duplicate ACK because dup_acks
  #      was incremented after process_acks read it (should fire on the 3rd).
  #   3. Selective-ACK punched holes into `unacked`, then the next cumulative
  #      ACK skipped legitimate acknowledgements because the old code assumed
  #      a contiguous range from seq_nr - in_flight.
  #   4. LEDBAT used a 240-sample cap instead of a wall-clock 2-minute window,
  #      and had no hard `max_window` ceiling.
  #   5. `transmit/5` reset tx_count to 1 on every retransmit, making the
  #      give-up branch (tx_count >= 10) unreachable.
  use ExUnit.Case, async: true

  alias UTP.{LEDBAT, Packet}

  # ---------- LEDBAT: 2-minute window ----------
  test "LEDBAT ages samples out of the base_delay window after 2 minutes" do
    led = LEDBAT.new()

    now = System.monotonic_time(:millisecond)
    # A very small (fast) delay recorded 3 minutes ago should be dropped so
    # the current 100 ms sample becomes the new base rather than a 3-minute-
    # old outlier.
    stale_sample = {1_000, now - 180_000}
    led = %{led | delay_samples: [stale_sample], base_delay: 1_000}

    led = LEDBAT.record_delay(led, 100_000)

    assert led.base_delay == 100_000
    assert length(led.delay_samples) == 1
  end

  test "LEDBAT max_window is bounded by the hard ceiling" do
    led = LEDBAT.new()
    # Bypass slow-start so we exercise the proportional-gain branch.
    led = %{led | slow_start: false, max_window: 900_000, last_off_target: 100_000}

    # Repeatedly grow with a huge peer_wnd — under the old code max_window
    # would ramp unbounded. Now it must be capped ~= 1 MiB.
    led = Enum.reduce(1..200, led, fn _, acc ->
      LEDBAT.grow_window(acc, acc.max_window, 10_000_000)
    end)

    assert led.max_window <= 1_048_576
  end

  test "LEDBAT slow-start doubles the window until off_target flips negative" do
    led = LEDBAT.new()
    assert led.slow_start
    initial = led.max_window
    # off_target > 0 means queue is empty → keep growing.
    led = %{led | last_off_target: 90_000}
    led = LEDBAT.grow_window(led, 0, 100_000)
    assert led.max_window > initial
    assert led.slow_start

    # Once queue starts filling, slow start ends and we fall through to the
    # LEDBAT proportional branch.
    led = %{led | last_off_target: -1000, max_window: 65_536}
    led2 = LEDBAT.grow_window(led, 65_536, 65_536)
    refute led2.slow_start
  end

  # ---------- Connection: selective-ACK + cumulative-ACK interplay ----------
  test "cumulative ack still fires after selective-ack punches holes in unacked" do
    # Drive process_acks directly via the private helper by constructing a
    # state that mirrors "we've sent 8..12, peer selective-acked 10, next
    # packet arrives with a higher cumulative ack".
    initial = %UTP.Connection{
      udp_socket: :placeholder,
      peer_ip: {127, 0, 0, 1},
      peer_port: 0,
      recv_conn_id: 0,
      send_conn_id: 0,
      seq_nr: 13,
      unacked: %{
        8 => {<<0>>, 0, 1, 1},
        9 => {<<0>>, 0, 1, 1},
        10 => {<<0>>, 0, 1, 1},
        11 => {<<0>>, 0, 1, 1},
        12 => {<<0>>, 0, 1, 1}
      },
      cur_window: 5,
      led: LEDBAT.new()
    }

    hdr = %Packet{
      type: Packet.st_state(),
      version: 1,
      extension: 0,
      conn_id: 0,
      timestamp: 0,
      timestamp_difference: 0,
      wnd_size: 65_536,
      seq_nr: 100,
      ack_nr: 9
    }

    # Selective-ack seqs 11 and 12 (offsets 2 and 3 relative to ack_nr).
    # Header ack_nr=9 → cumulative acks {8, 9}. Combined result: only 10 left.
    bitmask = <<0b0011::size(8)>>
    state = run_packet(initial, hdr, [{:selective_ack, bitmask}])
    assert Map.keys(state.unacked) == [10]

    # A follow-up packet with ack_nr=10 cumulative-acks the last remaining seq.
    # Under the old contiguous-assumption bug, base was derived from
    # (seq_nr - in_flight) and this ack was skipped as out-of-range.
    hdr2 = %{hdr | ack_nr: 10}
    state = run_packet(state, hdr2, [])
    assert state.unacked == %{}
  end

  # process_acks/3 is private — reach it by shoving state into a live
  # GenServer and sending a packet through the regular handle_info entry.
  defp run_packet(state, header, extensions) do
    unless Process.whereis(UTP.Dispatcher) do
      {:ok, _} = UTP.Dispatcher.start_link([])
    end

    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    state = %{state | udp_socket: udp, phase: :connected}

    {:ok, pid} = GenServer.start(UTP.Connection, state)
    :sys.replace_state(pid, fn _ -> state end)
    send(pid, {:utp_packet, header, <<>>, extensions})
    Process.sleep(20)
    result = :sys.get_state(pid)
    GenServer.stop(pid, :normal)
    :gen_udp.close(udp)
    result
  end
end

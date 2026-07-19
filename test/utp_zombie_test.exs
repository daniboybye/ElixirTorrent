defmodule UTPZombieTest do
  # Regression tests for the uTP zombie leak fix.
  #
  # Before the fix, shutdown/2 was a pure state transformation — it flipped
  # closed:/phase: fields but never stopped the GenServer. Any peer-initiated
  # close (ST_RESET, FIN sequence, retransmit give-up) or a dead owner left the
  # process alive, ticking every @tick_ms forever.
  #
  # Live-node reproduction on 2026-07-17: ~78% of uTP processes were
  # dead-but-alive, burning ~370k reductions/sec.

  use ExUnit.Case, async: false

  alias UTP.{Connection, Packet}

  setup do
    unless Process.whereis(UTP.Dispatcher) do
      {:ok, _pid} = UTP.Dispatcher.start_link([])
    end

    :ok
  end

  test "peer ST_RESET tears down the GenServer" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 20_001
    recv_id = 21_001

    assert {:ok, {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)
    ref = Process.monitor(pid)

    reset = %Packet{
      type: Packet.st_reset(),
      version: 1,
      extension: 0,
      conn_id: recv_id,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 0,
      seq_nr: 1,
      ack_nr: 0
    }

    send(pid, {:utp_packet, reset, <<>>, []})

    # Linger is @linger_ms (1000ms); give it a comfortable margin.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_500

    :gen_udp.close(udp)
  end

  test "owner death tears down the GenServer" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 20_002
    recv_id = 21_002

    assert {:ok, {:utp, pid} = ref_sock} = Connection.start_client(udp, ip, port, conn_id: recv_id)

    owner =
      spawn(fn ->
        receive do
          :die -> :ok
        end
      end)

    :ok = Connection.controlling_process(ref_sock, owner)
    conn_ref = Process.monitor(pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^conn_ref, :process, ^pid, :normal}, 2_500

    :gen_udp.close(udp)
  end

  test "schedule_tick is a no-op after shutdown so a closed connection stops ticking" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 20_003
    recv_id = 21_003

    assert {:ok, {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)

    reset = %Packet{
      type: Packet.st_reset(),
      version: 1,
      extension: 0,
      conn_id: recv_id,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 0,
      seq_nr: 1,
      ack_nr: 0
    }

    send(pid, {:utp_packet, reset, <<>>, []})

    # Wait long enough for shutdown to complete but before the linger stop fires.
    Process.sleep(100)

    state = :sys.get_state(pid)
    assert state.closed == true
    assert state.phase == :closed
    assert state.timer_ref == nil

    :gen_udp.close(udp)
  end
end

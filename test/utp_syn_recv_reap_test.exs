defmodule UtpSynRecvReapTest do
  use ExUnit.Case, async: true

  alias UTP.Connection

  test "a server connection whose peer never follows the SYN is closed" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(udp) end)

    {:ok, {:utp, pid}} = Connection.start_server(udp, {127, 0, 0, 1}, 9, 100)

    # A silent handshake: pretend the last packet either way was a minute ago.
    long_ago = System.monotonic_time(:millisecond) - 60_000

    :sys.replace_state(pid, fn state ->
      %{state | activity: %{state.activity | last_send_ms: long_ago, last_recv_ms: long_ago}}
    end)

    send(pid, :tick)
    # `:sys.get_state` queues behind the tick, so no sleep is needed.
    assert %{closed: true, phase: :closed} = :sys.get_state(pid)
    Process.exit(pid, :kill)
  end

  test "a fresh server connection survives the tick" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(udp) end)

    {:ok, {:utp, pid}} = Connection.start_server(udp, {127, 0, 0, 1}, 9, 100)

    :sys.replace_state(pid, fn state ->
      now = System.monotonic_time(:millisecond)
      %{state | activity: %{state.activity | last_send_ms: now, last_recv_ms: now}}
    end)

    send(pid, :tick)
    assert :sys.get_state(pid).phase == :syn_recv
    Process.exit(pid, :kill)
  end
end

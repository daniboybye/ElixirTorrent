defmodule UTPClientRecvTest do
  use ExUnit.Case, async: false

  alias UTP.{Connection, Packet}

  setup do
    unless Process.whereis(UTP.Dispatcher) do
      {:ok, _pid} = UTP.Dispatcher.start_link([])
    end

    :ok
  end

  test "outbound client accepts peer DATA at ST_STATE seq_nr" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_999
    recv_id = 10_001
    peer_seq = 5000

    assert {:ok, {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)

    state_header = %Packet{
      type: Packet.st_state(),
      version: 1,
      extension: 0,
      conn_id: recv_id,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 65_536,
      seq_nr: peer_seq,
      ack_nr: 1
    }

    send(pid, {:utp_packet, state_header, <<>>, []})
    assert :ok = Connection.await_connected({:utp, pid}, 1_000)

    payload = :crypto.strong_rand_bytes(68)

    data_header = %Packet{
      type: Packet.st_data(),
      version: 1,
      extension: 0,
      conn_id: recv_id,
      timestamp: 2,
      timestamp_difference: 0,
      wnd_size: 65_536,
      seq_nr: peer_seq,
      ack_nr: 2
    }

    send(pid, {:utp_packet, data_header, payload, []})
    assert {:ok, ^payload} = Connection.recv_raw({:utp, pid}, 68, 1_000)

    :ok = Connection.close({:utp, pid})
    :gen_udp.close(udp)
  end

  test "sends data when peer advertises a window smaller than max packet size" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_998
    recv_id = 10_002

    assert {:ok, {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)

    state_header = %Packet{
      type: Packet.st_state(),
      version: 1,
      extension: 0,
      conn_id: recv_id,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 200,
      seq_nr: 9000,
      ack_nr: 1
    }

    send(pid, {:utp_packet, state_header, <<>>, []})
    assert :ok = Connection.await_connected({:utp, pid}, 1_000)
    assert :ok = Connection.send_raw({:utp, pid}, :crypto.strong_rand_bytes(68))

    assert %{pending_send: <<>>} = :sys.get_state(pid)

    :ok = Connection.close({:utp, pid})
    :gen_udp.close(udp)
  end

  test "clears unacked data when peer ack_nr covers our send seq" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_997
    recv_id = 10_003

    assert {:ok, {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)

    state_header = %Packet{
      type: Packet.st_state(),
      version: 1,
      extension: 0,
      conn_id: recv_id,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 65_536,
      seq_nr: 8000,
      ack_nr: 1
    }

    send(pid, {:utp_packet, state_header, <<>>, []})
    assert :ok = Connection.await_connected({:utp, pid}, 1_000)
    assert :ok = Connection.send_raw({:utp, pid}, :crypto.strong_rand_bytes(68))

    %{unacked: unacked, seq_nr: seq_nr} = :sys.get_state(pid)
    assert map_size(unacked) == 1
    assert seq_nr == 3

    ack_header = %Packet{
      type: Packet.st_state(),
      version: 1,
      extension: 0,
      conn_id: recv_id,
      timestamp: 2,
      timestamp_difference: 0,
      wnd_size: 65_536,
      seq_nr: 8000,
      ack_nr: 2
    }

    send(pid, {:utp_packet, ack_header, <<>>, []})

    %{unacked: cleared, cur_window: cur_window} = :sys.get_state(pid)
    assert map_size(cleared) == 0
    assert cur_window == 0

    :ok = Connection.close({:utp, pid})
    :gen_udp.close(udp)
  end
end

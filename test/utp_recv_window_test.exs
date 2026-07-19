defmodule UTPRecvWindowTest do
  # Regression: previously recv_used was a running counter that grew on every
  # inbound payload but was never decremented when the reader consumed bytes,
  # AND the OOB path double-charged (once on parking, once on drain-through
  # deliver_payload). Both bugs pushed the advertised wnd_size to 0 after
  # ~64 KiB, stalling every uTP transfer at that size.
  use ExUnit.Case, async: false

  alias UTP.{Connection, Packet}

  setup do
    unless Process.whereis(UTP.Dispatcher) do
      {:ok, _pid} = UTP.Dispatcher.start_link([])
    end

    :ok
  end

  defp handshake!(pid, recv_id, peer_seq) do
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
    :ok = Connection.await_connected({:utp, pid}, 1_000)
  end

  defp data_packet(recv_id, peer_seq, payload) do
    %Packet{
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
    |> then(&{&1, payload})
  end

  test "reader consumption drives recv accounting so wnd never collapses past 64 KiB" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_881
    recv_id = 20_001
    peer_seq = 5000

    assert {:ok, {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)
    handshake!(pid, recv_id, peer_seq)

    chunk = :crypto.strong_rand_bytes(1000)
    packets = 100

    # Feed 100 KiB of in-order data. If the old bug were still present,
    # recv_used would climb to ~100 KiB and clamp wnd_size to 0 forever.
    Enum.each(0..(packets - 1), fn i ->
      {hdr, payload} = data_packet(recv_id, Packet.seq_add(peer_seq, i), chunk)
      send(pid, {:utp_packet, hdr, payload, []})
    end)

    # Drain everything back to the reader — this MUST clear the internal
    # accounting so subsequent packets keep getting a healthy window.
    total = 1000 * packets
    assert {:ok, drained} = Connection.recv_raw({:utp, pid}, total, 2_000)
    assert byte_size(drained) == total

    state = :sys.get_state(pid)
    assert state.recv_buffer == <<>>
    assert state.recv_oob == %{}

    :ok = Connection.close({:utp, pid})
    :gen_udp.close(udp)
  end

  test "OOB packets are not double-counted when later drained" do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_882
    recv_id = 20_002
    peer_seq = 6000

    assert {:ok, {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)
    handshake!(pid, recv_id, peer_seq)

    payload_a = :crypto.strong_rand_bytes(500)
    payload_b = :crypto.strong_rand_bytes(500)

    # Deliver seq+1 first (goes into recv_oob), then seq (in-order arrival
    # drains OOB via deliver_payload). Under the old bug, payload_b's bytes
    # were charged once when parked and again when delivered — inflating
    # recv_used by 500 bytes per OOB event.
    {hdr_b, _} = data_packet(recv_id, Packet.seq_add(peer_seq, 1), payload_b)
    send(pid, {:utp_packet, hdr_b, payload_b, []})

    {hdr_a, _} = data_packet(recv_id, peer_seq, payload_a)
    send(pid, {:utp_packet, hdr_a, payload_a, []})

    # Read the whole 1000 bytes back — buffer must fully drain and OOB must
    # be empty. No leftover accounting means our advertised window stays open.
    assert {:ok, combined} = Connection.recv_raw({:utp, pid}, 1000, 2_000)
    assert combined == payload_a <> payload_b

    state = :sys.get_state(pid)
    assert state.recv_buffer == <<>>
    assert state.recv_oob == %{}

    :ok = Connection.close({:utp, pid})
    :gen_udp.close(udp)
  end
end

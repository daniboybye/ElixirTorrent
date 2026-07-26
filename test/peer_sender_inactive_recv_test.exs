defmodule Peer.SenderInactiveRecvTest do
  use ExUnit.Case, async: false

  alias Peer.LTEP.{Handshake, Session}
  alias UTP.{Connection, Packet}

  setup do
    unless Process.whereis(UTP.Dispatcher) do
      {:ok, _} = UTP.Dispatcher.start_link([])
    end

    :ok
  end

  test "inactive Sender buffers uTP active delivery for socket_recv (BEP 9 swarm path)" do
    hash = :crypto.strong_rand_bytes(20)
    id = <<9::160>>
    key = Peer.make_key(hash, id)

    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_880
    recv_id = 10_880
    peer_seq = 6000

    assert {:ok, utp = {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)

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
    assert :ok = Connection.await_connected(utp, 1_000)

    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, utp])
    assert :ok = Peer.Transport.controlling_process(utp, sender_pid)
    assert :ok = Peer.Sender.activate(key)
    assert :ok = Peer.Sender.deactivate(key)

    wire = ut_metadata_data_wire(0, 128, <<0::128>>)

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

    send(pid, {:utp_packet, data_header, wire, []})

    assert {:ok, <<length::32>>} = Peer.Sender.socket_recv(key, 4, 1_000)
    assert length >= 2

    assert {:ok, body} = Peer.Sender.socket_recv(key, length, 1_000)
    assert <<20, 1, _payload::binary>> = body

    on_exit(fn ->
      TestSupport.Sync.safe_stop(sender_pid, 1_000)
      Connection.close(utp)
      :gen_udp.close(udp)
    end)
  end

  test "active Sender keeps uTP window charged until its buffered bytes are consumed" do
    hash = :crypto.strong_rand_bytes(20)
    id = <<7::160>>
    key = Peer.make_key(hash, id)

    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_882
    recv_id = 10_882
    peer_seq = 8000

    assert {:ok, utp = {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)

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
    assert :ok = Connection.await_connected(utp, 1_000)

    # Deliberately incomplete peer-wire message. The first half arrives while
    # Connection is passive and is transferred into Sender on activate; the
    # second arrives through active delivery.
    wire = <<100::32, 20, 1, 0, 0, 2, 3, 4, 5>>
    <<passive_part::binary-size(6), active_part::binary>> = wire

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

    send(pid, {:utp_packet, data_header, passive_part, []})
    assert %UTP.Connection{recv_buffer: ^passive_part} = TestSupport.Sync.sync(pid)

    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, utp])
    assert :ok = Peer.Transport.controlling_process(utp, sender_pid)
    assert :ok = Peer.Sender.activate(key)

    assert %Peer.Sender{utp_held_bytes: held} = TestSupport.Sync.sync(sender_pid)
    assert held == byte_size(passive_part)

    assert %UTP.Connection{active_recv_bytes: ^held} = TestSupport.Sync.sync(pid)

    active_header = %{data_header | seq_nr: Packet.seq_add(peer_seq, 1)}
    send(pid, {:utp_packet, active_header, active_part, []})
    TestSupport.Sync.sync(pid)
    TestSupport.Sync.sync(sender_pid)

    wire_size = byte_size(wire)
    assert %Peer.Sender{utp_held_bytes: ^wire_size} = TestSupport.Sync.sync(sender_pid)
    assert %UTP.Connection{active_recv_bytes: ^wire_size} = TestSupport.Sync.sync(pid)

    assert :ok = Peer.Sender.deactivate(key)
    assert {:ok, ^wire} = Peer.Sender.socket_recv(key, byte_size(wire), 1_000)
    assert %Peer.Sender{utp_held_bytes: 0} = TestSupport.Sync.sync(sender_pid)
    assert %UTP.Connection{active_recv_bytes: 0} = TestSupport.Sync.sync(pid)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(sender_pid, 1_000)
      Connection.close(utp)
      :gen_udp.close(udp)
    end)
  end

  @tag race_group: :protocol
  test "swarm request_piece receives ut_metadata data after Sender deactivate" do
    hash = :crypto.strong_rand_bytes(20)
    id = <<8::160>>
    key = Peer.make_key(hash, id)

    {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
    ip = {127, 0, 0, 1}
    port = 19_881
    recv_id = 10_881
    peer_seq = 7000

    assert {:ok, utp = {:utp, pid}} = Connection.start_client(udp, ip, port, conn_id: recv_id)

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
    assert :ok = Connection.await_connected(utp, 1_000)

    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, utp])
    assert :ok = Peer.Transport.controlling_process(utp, sender_pid)
    assert :ok = Peer.Sender.activate(key)
    assert :ok = Peer.Sender.deactivate(key)

    peer_hs = %Handshake{m: %{"ut_metadata" => 2}, metadata_size: 256}
    ltep = Session.new() |> Session.apply_peer_handshake(peer_hs)

    conn = %Magnet.Connection{
      socket: nil,
      peer_key: key,
      ltep: ltep,
      metadata_size: 256,
      transport: :swarm,
      peer: nil,
      unchoked?: true,
      unchoke_since: System.monotonic_time(:millisecond)
    }

    total_size = 256
    piece_data = :binary.copy(<<0xAB>>, total_size)
    response_wire = ut_metadata_data_wire(0, total_size, piece_data)

    parent = self()
    release = make_ref()

    task =
      Task.async(fn ->
        send(parent, {:metadata_request_ready, self()})
        receive do: (^release -> :ok)
        Magnet.Connection.request_piece(conn, 0)
      end)

    assert_receive {:metadata_request_ready, task_pid}, 2_000
    assert task.pid == task_pid
    1 = :erlang.trace(task.pid, true, [:send])
    send(task.pid, release)

    assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _, {:socket_recv, _, _}},
                    ^sender_pid},
                   2_000

    _ = :erlang.trace(task.pid, false, [:send])

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

    send(pid, {:utp_packet, data_header, response_wire, []})

    assert {:ok, ^piece_data, ^total_size} = Task.await(task, 5_000)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(sender_pid, 1_000)
      Connection.close(utp)
      :gen_udp.close(udp)
    end)
  end

  defp ut_metadata_data_wire(piece, total_size, data) do
    payload = Magnet.UtMetadata.encode_data(piece, total_size, data)
    Peer.LTEP.extended_message_wire(1, payload)
  end
end

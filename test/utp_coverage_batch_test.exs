defmodule UTP.CoverageBatchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias UTP.{Connection, Dispatcher, LEDBAT, Packet}

  @ip {127, 0, 0, 1}
  @port 19_500

  setup do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end

    previous_dht = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :dht, previous_dht)
    end)

    {:ok, previous_dht: previous_dht}
  end

  describe "Connection.handle_call/3 direct state transitions" do
    test "activate/deactivate idempotent branches and take_recv_buffer" do
      state = base_state(active: true)

      assert {:reply, :ok, still_active} = Connection.handle_call(:activate, from(), state)
      assert still_active.active

      assert {:reply, :ok, inactive} = Connection.handle_call(:deactivate, from(), still_active)
      refute inactive.active

      assert {:reply, :ok, active_again} = Connection.handle_call(:activate, from(), inactive)
      assert active_again.active

      buffered = %{active_again | recv_buffer: <<"hello">>, active_recv_bytes: 0}

      assert {:reply, <<"hello">>, cleared} =
               Connection.handle_call(:take_recv_buffer, from(), buffered)

      assert cleared.recv_buffer == <<>>
      assert cleared.active_recv_bytes == 5
    end

    test "controlling_process replaces owner monitor" do
      {old_owner, old_mon, old_release} = TestSupport.Sync.spawn_blocked()
      {new_owner, _new_mon, new_release} = TestSupport.Sync.spawn_blocked()

      state =
        base_state(phase: :connected)
        |> Map.put(:owner, old_owner)
        |> Map.put(:owner_ref, old_mon)

      assert {:reply, :ok, updated} =
               Connection.handle_call({:controlling_process, new_owner}, from(), state)

      assert updated.owner == new_owner
      assert is_reference(updated.owner_ref)
      refute updated.owner_ref == old_mon

      TestSupport.Sync.release(old_owner, old_release)
      TestSupport.Sync.release(new_owner, new_release)
    end

    test "await_connected replies immediately or queues waiter" do
      connected = base_state(phase: :connected)

      assert {:reply, :ok, ^connected} =
               Connection.handle_call(:await_connected, from(), connected)

      waiting = base_state(phase: :syn_sent)
      caller = from()

      assert {:noreply, queued} = Connection.handle_call(:await_connected, caller, waiting)
      assert [{^caller, :connected}] = queued.recv_waiters
    end

    test "recv serves from buffer or registers byte waiter" do
      ready = %{base_state() | recv_buffer: <<"abcdef">>}

      assert {:reply, {:ok, <<"abc">>}, rest} =
               Connection.handle_call({:recv, 3, 0}, from(), ready)

      assert rest.recv_buffer == <<"def">>

      caller = from()
      empty = base_state()

      assert {:noreply, waiting} = Connection.handle_call({:recv, 4, 0}, caller, empty)
      assert [{^caller, 4, timer}] = waiting.recv_waiters
      assert is_reference(timer)
    end

    test "peername and send flush connected pending data" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)

      state =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: 501,
          send_conn_id: 502,
          seq_nr: 10,
          ack_nr: 5,
          led: LEDBAT.new()
        )

      assert {:reply, {:ok, {@ip, ^peer_port}}, ^state} =
               Connection.handle_call(:peername, from(), state)

      assert {:reply, :ok, flushed} =
               Connection.handle_call({:send, "payload"}, from(), %{state | pending_send: "xy"})

      assert flushed.pending_send == <<>>
      assert map_size(flushed.unacked) == 1
      assert {:ok, {_ip, _port, wire}} = :gen_udp.recv(peer_udp, 0, 1_000)
      assert {:ok, %{type: data_type}, decoded_payload, _} = Packet.decode(wire)
      assert data_type == Packet.st_data()
      assert decoded_payload == "xypayload"

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end
  end

  describe "Connection.handle_cast/2 and recv timeout handle_info" do
    test "close in pre-connected phase shuts down immediately" do
      state = base_state(phase: :syn_sent, recv_conn_id: 601, send_conn_id: 602)

      assert {:stop, :normal, closed} = Connection.handle_cast(:close, state)
      assert closed.closed
      assert closed.phase == :closed
    end

    test "close on connected sends FIN once" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)

      state =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: 701,
          send_conn_id: 702,
          seq_nr: 3,
          ack_nr: 2,
          led: LEDBAT.new()
        )

      assert {:noreply, once} = Connection.handle_cast(:close, state)
      assert once.fin_sent
      assert {:ok, {_ip, _port, fin_wire}} = :gen_udp.recv(peer_udp, 0, 1_000)
      assert {:ok, %{type: fin_type}, <<>>, _} = Packet.decode(fin_wire)
      assert fin_type == Packet.st_fin()

      assert {:noreply, ^once} = Connection.handle_cast(:close, once)

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end

    test "active_recv_consumed decrements active bytes" do
      state = %{base_state() | active_recv_bytes: 100}

      assert {:noreply, %{active_recv_bytes: 40}} =
               Connection.handle_cast({:active_recv_consumed, 60}, state)
    end

    test "recv_timeout replies current waiter and ignores stale from" do
      current = from()
      stale = from()
      state = %{base_state() | recv_waiters: [{current, 8, make_ref()}]}

      assert {:noreply, cleared} = Connection.handle_info({:recv_timeout, current}, state)
      assert cleared.recv_waiters == []
      assert_receive {ref, {:error, :timeout}} when is_reference(ref)

      assert {:noreply, ^cleared} = Connection.handle_info({:recv_timeout, stale}, cleared)
      assert_receive {ref2, {:error, :timeout}} when is_reference(ref2)
    end
  end

  describe "Connection.handle_info/2 SYN and handshake paths" do
    test "client ST_STATE in syn_sent connects and server ST_STATE in syn_recv accepts once" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)
      recv_id = 801
      peer_seq = 1200

      client =
        base_state(
          role: :client,
          phase: :syn_sent,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: recv_id,
          send_conn_id: recv_id + 1,
          seq_nr: 1
        )

      client_hdr = header(Packet.st_state(), recv_id, peer_seq, 1)

      assert {:noreply, connected} =
               Connection.handle_info({:utp_packet, client_hdr, <<>>, []}, client)

      assert connected.phase == :connected
      assert connected.recv_next == peer_seq
      assert connected.ack_nr == Packet.seq_add(peer_seq, -1)
      assert {:ok, {_ip, _port, _ack}} = :gen_udp.recv(peer_udp, 0, 1_000)

      server =
        base_state(
          role: :server,
          phase: :syn_recv,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: recv_id + 1,
          send_conn_id: recv_id,
          seq_nr: 900,
          recv_next: 900,
          socket_ref: {:utp, self()},
          accept_notified: false
        )

      server_hdr = header(Packet.st_state(), recv_id + 1, peer_seq, 900)

      assert {:noreply, accepted} =
               Connection.handle_info({:utp_packet, server_hdr, <<>>, []}, server)

      assert accepted.phase == :connected
      assert accepted.accept_notified

      assert {:noreply, again} =
               Connection.handle_info({:utp_packet, server_hdr, <<>>, []}, accepted)

      assert again.accept_notified
      assert again.phase == :connected

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end

    test "server SYN in syn_recv sends state ack and server DATA promotes to connected" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)
      syn_id = 810
      recv_id = rem(syn_id + 1, 65_536)
      peer_seq = 2000

      server =
        base_state(
          role: :server,
          phase: :syn_recv,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: recv_id,
          send_conn_id: syn_id,
          seq_nr: 500,
          recv_next: 500,
          socket_ref: {:utp, self()}
        )

      syn_hdr = header(Packet.st_syn(), syn_id, peer_seq, 0)

      assert {:noreply, after_syn} =
               Connection.handle_info({:utp_packet, syn_hdr, <<>>, []}, server)

      assert after_syn.ack_nr == peer_seq
      assert after_syn.recv_next == Packet.seq_add(peer_seq, 1)
      assert {:ok, {_ip, _port, _state_ack}} = :gen_udp.recv(peer_udp, 0, 1_000)

      data_only =
        base_state(
          role: :server,
          phase: :syn_recv,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: recv_id,
          send_conn_id: syn_id,
          seq_nr: 501,
          recv_next: peer_seq,
          socket_ref: {:utp, self()},
          accept_notified: false
        )

      data_hdr = header(Packet.st_data(), recv_id, peer_seq, 501)

      assert {:noreply, promoted} =
               Connection.handle_info({:utp_packet, data_hdr, <<"early">>, []}, data_only)

      assert promoted.phase == :connected
      assert promoted.accept_notified
      assert promoted.recv_buffer == <<"early">>

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end

    test "connected ST_STATE and ignored SYN/wrong conn_id/unknown type" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)

      state =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: 901,
          send_conn_id: 902,
          seq_nr: 4,
          ack_nr: 3,
          led: LEDBAT.new()
        )

      keepalive = header(Packet.st_state(), 901, 100, 3)

      assert {:noreply, acked} =
               Connection.handle_info({:utp_packet, keepalive, <<>>, []}, state)

      assert acked.phase == :connected
      assert acked.last_peer_ack == 3
      assert {:ok, {_ip, _port, _ack}} = :gen_udp.recv(peer_udp, 0, 1_000)

      wrong_id = %{keepalive | conn_id: 999}

      assert {:noreply, ignored} =
               Connection.handle_info({:utp_packet, wrong_id, <<>>, []}, acked)

      assert ignored == acked

      stray_syn = header(Packet.st_syn(), 901, 50, 0)

      assert {:noreply, no_syn} =
               Connection.handle_info({:utp_packet, stray_syn, <<>>, []}, acked)

      assert no_syn.phase == :connected

      unknown = %{keepalive | type: 99}

      assert {:noreply, no_type} =
               Connection.handle_info({:utp_packet, unknown, <<>>, []}, acked)

      assert no_type.phase == :connected

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end
  end

  describe "Connection.handle_info/2 inbound DATA/FIN/RESET and ordering" do
    test "in-order, out-of-order, stale drop, and empty payload" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)
      recv_id = 1001
      peer_seq = 3000

      state =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: recv_id,
          send_conn_id: recv_id + 1,
          seq_nr: 2,
          ack_nr: 1,
          recv_next: peer_seq,
          led: LEDBAT.new()
        )

      future = header(Packet.st_data(), recv_id, Packet.seq_add(peer_seq, 2), 1)

      assert {:noreply, oob} =
               Connection.handle_info({:utp_packet, future, <<"late">>, []}, state)

      assert map_size(oob.recv_oob) == 1
      assert {:ok, {_ip, _port, _sack_ack}} = :gen_udp.recv(peer_udp, 0, 1_000)

      stale = header(Packet.st_data(), recv_id, Packet.seq_add(peer_seq, -1), 1)

      assert {:noreply, dropped} =
               Connection.handle_info({:utp_packet, stale, <<"old">>, []}, oob)

      assert dropped.recv_next == oob.recv_next
      assert {:ok, {_ip, _port, _drop_ack}} = :gen_udp.recv(peer_udp, 0, 1_000)

      in_order = header(Packet.st_data(), recv_id, peer_seq, 1)

      assert {:noreply, filled} =
               Connection.handle_info({:utp_packet, in_order, <<"a">>, []}, oob)

      assert filled.recv_buffer == <<"a">>
      assert filled.recv_next == Packet.seq_add(peer_seq, 1)

      empty = header(Packet.st_data(), recv_id, Packet.seq_add(peer_seq, 5), filled.ack_nr)

      assert {:noreply, unchanged} =
               Connection.handle_info({:utp_packet, empty, <<>>, []}, filled)

      assert unchanged.recv_buffer == filled.recv_buffer

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end

    test "FIN when disconnected is ignored; RESET and owner DOWN shut down" do
      pre = base_state(phase: :syn_sent, recv_conn_id: 1101)
      fin = header(Packet.st_fin(), 1101, 1, 0)

      assert {:noreply, ignored_fin} =
               Connection.handle_info({:utp_packet, fin, <<>>, []}, pre)

      assert ignored_fin.phase == :syn_sent

      reset = header(Packet.st_reset(), 1101, 1, 0)

      assert {:noreply, closed} =
               Connection.handle_info({:utp_packet, reset, <<>>, []}, ignored_fin)

      assert closed.closed

      owner = self()
      ref = Process.monitor(owner)
      owned = %{base_state(recv_conn_id: 1102, send_conn_id: 1103) | owner: owner, owner_ref: ref}

      assert {:noreply, down} =
               Connection.handle_info({:DOWN, ref, :process, owner, :kill}, owned)

      assert down.closed

      other_ref = make_ref()

      assert {:noreply, ^down} =
               Connection.handle_info({:DOWN, other_ref, :process, self(), :normal}, down)
    end

    test "active delivery posts to owner and dup-ack fast retransmit fires" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)

      owner = self()

      state =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: 1201,
          send_conn_id: 1202,
          seq_nr: 5,
          ack_nr: 2,
          recv_next: 100,
          active: true,
          owner: owner,
          socket_ref: {:utp, self()},
          led: LEDBAT.new(),
          unacked: %{3 => {Packet.st_data(), <<"x">>, System.monotonic_time(:millisecond), 1, 1}},
          last_peer_ack: 2,
          dup_acks: 0
        )

      data = header(Packet.st_data(), 1201, 100, 2)
      assert {:noreply, active} = Connection.handle_info({:utp_packet, data, <<"z">>, []}, state)
      assert_receive {:utp, {:utp, _}, <<"z">>}
      assert active.active_recv_bytes == 1

      dup =
        header(Packet.st_state(), 1201, 50, 2)
        |> Map.put(:ack_nr, 2)

      after_third =
        Enum.reduce(1..3, active, fn _, acc ->
          {:noreply, next} = Connection.handle_info({:utp_packet, dup, <<>>, []}, acc)
          next
        end)

      assert after_third.dup_acks >= 3
      {_, _, _, tx_count, _} = Map.fetch!(after_third.unacked, 3)
      assert tx_count >= 2

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end
  end

  describe "Connection.handle_info/2 tick timeouts, idle probes, and zombie stop" do
    test "retransmit timed-out unacked, give-up, zero-window probe, and closed tick noop" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)
      old_ms = System.monotonic_time(:millisecond) - 5_000

      retransmit_state =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: 1301,
          send_conn_id: 1302,
          seq_nr: 4,
          ack_nr: 1,
          timeout_ms: 500,
          led: LEDBAT.new(),
          unacked: %{2 => {Packet.st_data(), <<"q">>, old_ms, 1, 1}}
        )

      assert {:noreply, retried} = Connection.handle_info(:tick, retransmit_state)
      assert retried.timeout_ms == 1_000
      assert {:ok, {_ip, _port, _retry}} = :gen_udp.recv(peer_udp, 0, 1_000)

      give_up =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: 1303,
          send_conn_id: 1304,
          unacked: %{9 => {Packet.st_data(), <<>>, old_ms, 10, 1}},
          led: LEDBAT.new()
        )

      assert {:noreply, dead} = Connection.handle_info(:tick, give_up)
      assert dead.closed

      probe = idle_state(udp, peer_port, 1305, 1306, peer_wnd: 0, idle_probe_count: 0)

      assert {:noreply, probed} = Connection.handle_info(:tick, probe)
      assert probed.activity.idle_probe_count == 1
      assert {:ok, {_ip, _port, _probe_wire}} = :gen_udp.recv(peer_udp, 0, 1_000)

      max_probes =
        idle_state(udp, peer_port, 1307, 1308, peer_wnd: 0, idle_probe_count: 3)

      assert {:noreply, reaped} = Connection.handle_info(:tick, max_probes)
      assert reaped.closed

      closed_tick = %{reaped | timer_ref: nil}
      assert {:noreply, ^closed_tick} = Connection.handle_info(:tick, closed_tick)

      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end

    test "stop_zombie terminates cleanly" do
      state = %{base_state() | closed: true}
      assert {:stop, :normal, ^state} = Connection.handle_info(:stop_zombie, state)
    end
  end

  describe "Connection API exit normalization and send failure" do
    test "send_raw recv_raw peername on dead connection normalize exits" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])

      assert {:ok, {:utp, pid}} =
               Connection.start_client(udp, @ip, @port, conn_id: 1401)

      ref = Process.monitor(pid)
      reset = header(Packet.st_reset(), 1401, 1, 0)
      send(pid, {:utp_packet, reset, <<>>, []})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_500

      sock = {:utp, pid}
      assert {:error, :closed} = Connection.send_raw(sock, "x")
      assert {:error, :closed} = Connection.recv_raw(sock, 1, 0)
      assert {:error, :closed} = Connection.peername(sock)
      assert Connection.take_recv_buffer(sock) == <<>>

      :gen_udp.close(udp)
    end

    test "UDP send failure shuts connection down", context do
      previous_dht = context.previous_dht
      Application.put_env(:elixir_torrent, :dht, Keyword.put(previous_dht, :enabled, false))

      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      :ok = :gen_udp.close(udp)

      state =
        base_state(
          phase: :connected,
          udp_socket: udp,
          peer_port: @port,
          recv_conn_id: 1402,
          send_conn_id: 1403,
          seq_nr: 2,
          ack_nr: 1,
          led: LEDBAT.new()
        )

      hdr = header(Packet.st_state(), 1402, 10, 1)

      assert {:noreply, failed} =
               Connection.handle_info({:utp_packet, hdr, <<>>, []}, state)

      assert failed.closed
    end
  end

  describe "Dispatcher register/unregister/route/accept" do
    test "register_pair routes DATA and ignores garbage or unknown peers" do
      conn_id = 1501
      parent = self()

      conn =
        spawn(fn ->
          receive do
            {:utp_packet, header, payload, extensions} ->
              send(parent, {:routed, header.type, payload, extensions})
          end
        end)

      :ok = Dispatcher.register_pair(conn_id, rem(conn_id + 1, 65_536), @ip, @port, conn)

      data_hdr = header(Packet.st_data(), conn_id, 2, 1)
      bin = Packet.encode(data_hdr, <<"r">>)
      :ok = Dispatcher.dispatch(:dummy, @ip, @port, bin)
      assert_receive {:routed, 0, <<"r">>, []}, 1_000

      :ok = Dispatcher.dispatch(:dummy, @ip, @port, <<0xFF, 0xFF>>)
      :ok = Dispatcher.dispatch(:dummy, @ip, 9999, bin)

      :ok = Dispatcher.unregister_pair(conn_id, rem(conn_id + 1, 65_536), @ip, @port)
    end

    test "inbound SYN spawns server connection via route_packet" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)
      syn_id = 1510

      syn_hdr = header(Packet.st_syn(), syn_id, 400, 0)
      wire = Packet.encode(syn_hdr, <<>>)
      :ok = Dispatcher.dispatch(udp, @ip, peer_port, wire)
      _ = TestSupport.Sync.sync(Dispatcher)

      key = {@ip, peer_port, syn_id}
      assert [{^key, pid}] = :ets.lookup(:utp_connections, key)
      assert is_pid(pid)
      assert Process.alive?(pid)

      state = TestSupport.Sync.sync(pid)
      assert state.role == :server
      assert state.phase == :syn_recv

      TestSupport.Sync.safe_stop(pid)
      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end

    test "handle_call start_connect succeeds when DHT UDP is available" do
      assert {:reply, {:ok, {:utp, pid}}, %{}} =
               Dispatcher.handle_call({:start_connect, @ip, @port, [conn_id: 1601]}, from(), %{})

      assert is_pid(pid)
      assert Process.alive?(pid)
      TestSupport.Sync.safe_stop(pid)
    end

    # Running Application already binds DHT UDP; disabling env alone does not remove the socket.
    @tag :skip
    test "handle_call start_connect without UDP requires absent DHT socket (skip under running app)" do
      Application.put_env(:elixir_torrent, :dht, enabled: false)

      assert {:reply, {:error, :no_udp_socket}, %{}} =
               Dispatcher.handle_call({:start_connect, @ip, @port, []}, from(), %{})
    end

    test "handle_cast accept notifies handshakes task" do
      socket_ref = {:utp, self()}

      assert {:noreply, %{}} =
               Dispatcher.handle_cast({:accept, socket_ref, @ip, @port}, %{})
    end

    test "send_udp uses gen_udp fallback when DHT is disabled", context do
      previous_dht = context.previous_dht
      Application.put_env(:elixir_torrent, :dht, Keyword.put(previous_dht, :enabled, false))

      {:ok, server} =
        :gen_udp.open(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, client} =
        :gen_udp.open(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_server_ip, server_port}} = :inet.sockname(server)

      assert :ok = Dispatcher.send_udp(client, {127, 0, 0, 1}, server_port, "probe")
      assert {:ok, {_ip, _port, "probe"}} = :gen_udp.recv(server, 0, 1_000)

      :gen_udp.close(server)
      :gen_udp.close(client)
    end
  end

  describe "Connection boot, recv waiter satisfaction, and graceful terminate" do
    test "boot cast transmits client SYN and satisfy_recv_waiters completes blocked recv" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, peer_udp} = :gen_udp.open(0, [:binary, active: false])
      {:ok, {_peer_ip, peer_port}} = :inet.sockname(peer_udp)
      recv_id = 1701

      boot =
        base_state(
          role: :client,
          phase: :syn_sent,
          udp_socket: udp,
          peer_port: peer_port,
          recv_conn_id: recv_id,
          send_conn_id: recv_id + 1,
          seq_nr: 1,
          timer_ref: nil
        )

      assert {:noreply, _} = Connection.handle_cast({:boot, boot}, boot)
      assert {:ok, {_ip, _port, syn_wire}} = :gen_udp.recv(peer_udp, 0, 1_000)
      assert {:ok, %{type: syn_type}, <<>>, _} = Packet.decode(syn_wire)
      assert syn_type == Packet.st_syn()

      assert {:ok, {:utp, pid}} =
               Connection.start_client(udp, @ip, peer_port, conn_id: 1702)

      state_hdr = header(Packet.st_state(), 1702, 500, 1)
      send(pid, {:utp_packet, state_hdr, <<>>, []})
      assert :ok = Connection.await_connected({:utp, pid}, 1_000)

      data_hdr = header(Packet.st_data(), 1702, 500, 2)

      task =
        Task.async(fn ->
          Connection.recv_raw({:utp, pid}, 4, 5_000)
        end)

      send(pid, {:utp_packet, data_hdr, <<"wait">>, []})
      assert {:ok, "wait"} = Task.await(task, 1_000)

      TestSupport.Sync.safe_stop(pid)
      :gen_udp.close(peer_udp)
      :gen_udp.close(udp)
    end

    test "terminate/2 shuts down an open connection" do
      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])

      assert {:ok, {:utp, pid}} =
               Connection.start_client(udp, @ip, @port, conn_id: 1703)

      state = TestSupport.Sync.sync(pid)
      assert :ok = Connection.terminate(:shutdown, state)
      assert :ets.lookup(:utp_connections, {@ip, @port, 1703}) == []

      :gen_udp.close(udp)
    end
  end

  # --- helpers ---

  defp from, do: {self(), make_ref()}

  defp base_state(overrides \\ []) do
    now = System.monotonic_time(:millisecond)

    defaults = [
      udp_socket: :placeholder,
      peer_ip: @ip,
      peer_port: @port,
      recv_conn_id: 1,
      send_conn_id: 2,
      socket_ref: {:utp, self()},
      role: :client,
      phase: :syn_sent,
      seq_nr: 1,
      ack_nr: 0,
      recv_next: 1,
      led: LEDBAT.new(),
      activity: %{last_send_ms: now, last_recv_ms: now, idle_probe_count: 0}
    ]

    struct!(Connection, Keyword.merge(defaults, overrides))
  end

  defp idle_state(udp, peer_port, recv_id, send_id, opts) do
    now = System.monotonic_time(:millisecond)
    old = now - 120_001
    peer_wnd = Keyword.get(opts, :peer_wnd, 65_536)
    idle_probe_count = Keyword.get(opts, :idle_probe_count, 0)

    base_state(
      phase: :connected,
      udp_socket: udp,
      peer_port: peer_port,
      recv_conn_id: recv_id,
      send_conn_id: send_id,
      seq_nr: 2,
      ack_nr: 1,
      peer_wnd: peer_wnd,
      led: LEDBAT.new(),
      unacked: %{},
      activity: %{last_send_ms: old, last_recv_ms: old, idle_probe_count: idle_probe_count}
    )
  end

  defp header(type, conn_id, seq_nr, ack_nr) do
    %Packet{
      type: type,
      version: 1,
      extension: 0,
      conn_id: conn_id,
      timestamp: System.monotonic_time(:microsecond),
      timestamp_difference: 0,
      wnd_size: 65_536,
      seq_nr: seq_nr,
      ack_nr: ack_nr
    }
  end
end

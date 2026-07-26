defmodule Magnet.PexTest do
  use ExUnit.Case, async: false

  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias Peer.LTEP.{Extensions, Handshake, Session}
  alias Peer.UtPex
  alias Peer.UtPex.{Extension, InboundRate}

  defp pub4(n), do: {11, 0, 0, rem(n, 250)}

  defp manager_via(hash), do: {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}

  defp start_manager(hash) do
    {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: manager_via(hash))
    :sys.replace_state(pid, &%{&1 | dialing?: true})
    pid
  end

  defp start_private_model(hash) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"private" => 1, "name" => "private-magnet-pex"}},
      left: 1,
      last_index: 0,
      last_piece_length: 1,
      private?: true
    }

    start_supervised!({Torrent.Model, torrent})
  end

  setup do
    previous = Application.get_env(:elixir_torrent, :magnet_connection, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :magnet_connection, previous)
    end)

    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "magnet LTEP advertisement (PEX item 8)" do
    test "for_magnet includes ut_pex only when ConnectionManager consumer is active" do
      hash = :crypto.strong_rand_bytes(20)

      refute Extension in Extensions.for_magnet(hash)

      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      assert Extension in Extensions.for_magnet(hash)
    end

    test "for_magnet omits ut_pex when consume_pex is disabled" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      Application.put_env(:elixir_torrent, :magnet_connection, consume_pex: false)

      refute Extension in Extensions.for_magnet(hash)
    end

    test "for_magnet omits ut_pex for known private torrents" do
      hash = :crypto.strong_rand_bytes(20)
      _model = start_private_model(hash)
      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      refute Extension in Extensions.for_magnet(hash)
    end
  end

  describe "magnet inbound routing" do
    test "route_inbound_pex queues source-tagged peers via ConnectionManager" do
      hash = :crypto.strong_rand_bytes(20)
      supplier = <<11::160>>
      pex_peer = %Peer{ip: pub4(40), port: 9040}

      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      conn = base_conn(hash, supplier)

      payload = UtPex.encode([{pex_peer.ip, pex_peer.port}], [])
      conn = Magnet.Connection.route_inbound_pex_for_test(conn, payload)

      refute conn.pex_inbound.initial?

      state = :sys.get_state(pid)
      entry = Map.fetch!(state.queue, {pex_peer.ip, pex_peer.port})
      assert MapSet.member?(entry.sources, {:pex, supplier})
    end

    test "known private torrent rejects magnet PEX ingest" do
      hash = :crypto.strong_rand_bytes(20)
      _model = start_private_model(hash)
      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      conn = base_conn(hash, <<21::160>>)
      _ = Magnet.Connection.route_inbound_pex_for_test(conn, UtPex.encode([{pub4(44), 9044}], []))

      assert :sys.get_state(pid).queue == %{}
    end

    test "rate limit within window does not mutate queue" do
      hash = :crypto.strong_rand_bytes(20)
      supplier = <<12::160>>
      pex_peer = %Peer{ip: pub4(41), port: 9041}

      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      conn = base_conn(hash, supplier)
      payload = UtPex.encode([{pex_peer.ip, pex_peer.port}], [])

      conn = Magnet.Connection.route_inbound_pex_for_test(conn, payload)
      _conn = Magnet.Connection.route_inbound_pex_for_test(conn, payload)

      state = :sys.get_state(pid)
      assert map_size(state.queue) == 1
    end

    test "malformed payload consumes rate window without queue mutation" do
      hash = :crypto.strong_rand_bytes(20)
      supplier = <<13::160>>

      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      conn = base_conn(hash, supplier)
      conn = Magnet.Connection.route_inbound_pex_for_test(conn, "not-bencode")

      _conn =
        Magnet.Connection.route_inbound_pex_for_test(
          conn,
          UtPex.encode([{pub4(43), 9043}], [])
        )

      state = :sys.get_state(pid)
      assert map_size(state.queue) == 0
    end

    test "distinct magnet peers use separate PEX source ownership" do
      hash = :crypto.strong_rand_bytes(20)
      ep = %Peer{ip: pub4(42), port: 9042}
      supplier_a = <<14::160>>
      supplier_b = <<15::160>>

      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      conn_a = base_conn(hash, supplier_a)
      conn_b = base_conn(hash, supplier_b)

      payload = UtPex.encode([{ep.ip, ep.port}], [])

      conn_a = Magnet.Connection.route_inbound_pex_for_test(conn_a, payload)
      _ = Magnet.Connection.route_inbound_pex_for_test(conn_b, payload)

      conn_a =
        put_in(conn_a.pex_inbound.rate, %{
          initial?: false,
          anchor_ms: System.monotonic_time(:millisecond) - InboundRate.window_ms() - 1
        })

      _ =
        Magnet.Connection.route_inbound_pex_for_test(conn_a, UtPex.encode([], [{ep.ip, ep.port}]))

      state = :sys.get_state(pid)
      entry = Map.fetch!(state.queue, {ep.ip, ep.port})
      assert MapSet.member?(entry.sources, {:pex, supplier_b})
      refute MapSet.member?(entry.sources, {:pex, supplier_a})
    end
  end

  describe "loopback wire drain" do
    test "inbound ut_pex before ut_metadata still completes fetch_info" do
      info_map = %{
        "name" => "magnet-pex-loopback",
        "length" => 64,
        "piece length" => 16_384,
        "pieces" => <<0::160>>,
        "source" => :binary.copy("x", 17_000)
      }

      info_blob = Bento.encode!(info_map)
      hash = :crypto.hash(:sha, info_blob)
      metadata_size = byte_size(info_blob)
      remote_id = <<20::160>>
      pex_ep = {pub4(60), 9060}

      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      accept =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          serve_pex_then_metadata(socket, hash, remote_id, info_blob, metadata_size, pex_ep)
          :gen_tcp.close(listen)
          :ok
        end)

      assert {:ok, conn} =
               Magnet.Connection.open(%Peer{ip: {127, 0, 0, 1}, port: port}, hash)

      assert conn.pex_source == remote_id
      assert Session.local_extension_id(conn.ltep, "ut_pex") == 2

      assert {:ok, decoded, ^info_blob} = Magnet.Connection.fetch_info(conn, hash)
      assert decoded["name"] == "magnet-pex-loopback"

      state = :sys.get_state(pid)
      entry = Map.fetch!(state.queue, pex_ep)
      assert MapSet.member?(entry.sources, {:pex, remote_id})
      refute Map.has_key?(state.queue, {elem(pex_ep, 0), elem(pex_ep, 1) + 1})

      :gen_tcp.close(conn.socket)
      assert :ok = Task.await(accept, 5_000)
    end
  end

  describe "swarm path with deactivated Sender" do
    @tag race_group: :protocol
    test "ut_pex on wire during request_piece queues source-tagged peers" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<16::160>>
      key = Peer.make_key(hash, remote_id)
      pex_ep = {pub4(61), 9061}

      pid = start_manager(hash)
      on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)

      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])
      ip = {127, 0, 0, 1}
      port = 19_883
      recv_id = 10_883
      peer_seq = 9000

      assert {:ok, utp = {:utp, utp_pid}} =
               UTP.Connection.start_client(udp, ip, port, conn_id: recv_id)

      state_header = %UTP.Packet{
        type: UTP.Packet.st_state(),
        version: 1,
        extension: 0,
        conn_id: recv_id,
        timestamp: 1,
        timestamp_difference: 0,
        wnd_size: 65_536,
        seq_nr: peer_seq,
        ack_nr: 1
      }

      send(utp_pid, {:utp_packet, state_header, <<>>, []})
      assert :ok = UTP.Connection.await_connected(utp, 1_000)

      assert {:ok, sender_pid} = Peer.Sender.start_link([hash, remote_id, utp])
      assert :ok = Peer.Transport.controlling_process(utp, sender_pid)
      assert :ok = Peer.Sender.activate(key)
      assert :ok = Peer.Sender.deactivate(key)

      ltep =
        Session.new([Extension, UtMetadataExtension])
        |> Session.apply_peer_handshake(%Handshake{
          m: %{"ut_metadata" => 1, "ut_pex" => 3}
        })

      conn = %Magnet.Connection{
        socket: nil,
        peer_key: key,
        ltep: ltep,
        metadata_size: 128,
        hash: hash,
        pex_source: remote_id,
        transport: :swarm,
        peer: nil,
        unchoked?: true,
        unchoke_since: System.monotonic_time(:millisecond),
        pex_inbound: %{initial?: true, rate: InboundRate.initial()}
      }

      pex_wire =
        Peer.LTEP.extended_message_wire(
          Extension.local_id(),
          UtPex.encode([pex_ep], [])
        )

      response_wire = ut_metadata_data_wire(0, 128, :binary.copy(<<0xCD>>, 128))

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

      data_header = %UTP.Packet{
        type: UTP.Packet.st_data(),
        version: 1,
        extension: 0,
        conn_id: recv_id,
        timestamp: 2,
        timestamp_difference: 0,
        wnd_size: 65_536,
        seq_nr: peer_seq,
        ack_nr: 2
      }

      send(utp_pid, {:utp_packet, data_header, pex_wire <> response_wire, []})

      assert {:ok, _data, 128} = Task.await(task, 5_000)

      cm_state = :sys.get_state(pid)
      entry = Map.fetch!(cm_state.queue, pex_ep)
      assert MapSet.member?(entry.sources, {:pex, remote_id})

      on_exit(fn ->
        TestSupport.Sync.safe_stop(sender_pid, 1_000)
        UTP.Connection.close(utp)
        :gen_udp.close(udp)
      end)
    end
  end

  defp base_conn(hash, supplier) do
    ltep = Session.new([Extension, UtMetadataExtension])

    %Magnet.Connection{
      socket: nil,
      peer_key: nil,
      ltep: ltep,
      metadata_size: 4096,
      hash: hash,
      pex_source: supplier,
      transport: :tcp,
      peer: nil,
      unchoked?: true,
      unchoke_since: System.monotonic_time(:millisecond),
      pex_inbound: %{initial?: true, rate: InboundRate.initial()}
    }
  end

  defp ut_metadata_data_wire(piece, total_size, data) do
    payload = Magnet.UtMetadata.encode_data(piece, total_size, data)
    Peer.LTEP.extended_message_wire(1, payload)
  end

  defp serve_pex_then_metadata(socket, hash, remote_id, info_blob, metadata_size, pex_ep) do
    {:ok, client_hs} = :gen_tcp.recv(socket, 68, 5_000)
    <<19, "BitTorrent protocol"::binary, _::binary>> = client_hs

    :gen_tcp.send(
      socket,
      [<<19>>, "BitTorrent protocol", Peer.reserved(), hash, remote_id]
    )

    {:ok, <<len::32>>} = :gen_tcp.recv(socket, 4, 5_000)
    {:ok, <<20, 0, our_hs::binary>>} = :gen_tcp.recv(socket, len, 5_000)
    {:ok, our_dict} = Bento.decode(our_hs)
    our_ut_pex = get_in(our_dict, ["m", "ut_pex"])
    assert our_ut_pex == 2

    peer_hs =
      Bento.encode!(%{
        "m" => %{"ut_metadata" => 1, "ut_pex" => 3},
        "metadata_size" => metadata_size
      })

    :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(0, peer_hs))
    {:ok, <<0, 0, 0, 1, 2>>} = :gen_tcp.recv(socket, 5, 5_000)
    :gen_tcp.send(socket, <<0, 0, 0, 1, 1>>)

    pex_payload = UtPex.encode([pex_ep], [])
    pex_wire = Peer.LTEP.extended_message_wire(our_ut_pex, pex_payload)
    :gen_tcp.send(socket, pex_wire)

    loop_ut_metadata(socket, info_blob, our_ut_pex, pex_ep)
  catch
    _, _ -> :ok
  after
    :gen_tcp.close(socket)
  end

  defp loop_ut_metadata(socket, info_blob, our_ut_pex, pex_ep) do
    total_size = byte_size(info_blob)

    recv_loop = fn recv_loop ->
      recv_ut_metadata_loop(recv_loop, socket, info_blob, total_size, pex_ep, our_ut_pex)
    end

    recv_loop.(recv_loop)
  end

  defp recv_ut_metadata_loop(recv_loop, socket, info_blob, total_size, pex_ep, our_ut_pex) do
    case :gen_tcp.recv(socket, 4, 10_000) do
      {:ok, <<0, 0, 0, 0>>} ->
        recv_loop.(recv_loop)

      {:ok, <<len::32>>} ->
        handle_ut_metadata_frame(
          recv_loop,
          socket,
          len,
          info_blob,
          total_size,
          pex_ep,
          our_ut_pex
        )

      _ ->
        :ok
    end
  end

  defp handle_ut_metadata_frame(recv_loop, socket, len, info_blob, total_size, pex_ep, our_ut_pex) do
    case :gen_tcp.recv(socket, len, 10_000) do
      {:ok, <<20, _ext_id, payload::binary>>} ->
        dispatch_ut_metadata_payload(
          recv_loop,
          socket,
          payload,
          info_blob,
          total_size,
          pex_ep,
          our_ut_pex
        )

      _ ->
        :ok
    end
  end

  defp dispatch_ut_metadata_payload(
         recv_loop,
         socket,
         payload,
         info_blob,
         total_size,
         pex_ep,
         our_ut_pex
       ) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: piece]}} ->
        maybe_send_pex_on_piece(socket, piece, pex_ep, our_ut_pex)
        send_metadata_piece(socket, info_blob, total_size, piece)
        recv_loop.(recv_loop)

      _ ->
        recv_loop.(recv_loop)
    end
  end

  defp maybe_send_pex_on_piece(socket, piece, pex_ep, our_ut_pex) when piece > 0 do
    second_pex = UtPex.encode([{elem(pex_ep, 0), elem(pex_ep, 1) + 1}], [])
    :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(our_ut_pex, second_pex))
  end

  defp maybe_send_pex_on_piece(_socket, _piece, _pex_ep, _our_ut_pex), do: :ok

  defp send_metadata_piece(socket, info_blob, total_size, piece) do
    offset = piece * 16_384
    size = Magnet.UtMetadata.piece_byte_size(total_size, piece)
    data = binary_part(info_blob, offset, size)
    data = Magnet.UtMetadata.encode_data(piece, total_size, data)
    :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(1, data))
  end
end

defmodule PeerSenderLoopbackTest do
  # Loopback TCP + Registry-backed Sender/Controller stubs; not async-safe.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias Peer.{HashWire, LTEP}
  alias Peer.LTEP.Session
  alias PeerWireTest.ControllerCapture

  @piece_len Torrent.Downloads.piece_max_length()
  @timeout 5_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "Peer.LTEP recv_extended via Sender key" do
    test "returns message id 20, extended id, and payload when Sender is inactive" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      payload = "d2:id1i1ee"
      wire = LTEP.extended_message_wire(7, payload)
      assert :ok = :gen_tcp.send(server, wire)

      assert {:ok, 20, 7, ^payload} = LTEP.recv_extended(key, @timeout)
    end

    test "rejects length prefix below 2 without reading a body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      assert :ok = :gen_tcp.send(server, <<1::32>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(key, @timeout)
    end

    test "rejects length prefix above max_message_size without reading a body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      oversized = LTEP.max_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(key, @timeout)
    end
  end

  describe "Peer.LTEP handshake_exchange via Sender key" do
    test "merges peer handshake after optional preamble wire messages" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)

      exchange =
        Task.async(fn ->
          LTEP.handshake_exchange(key, Session.new([UtMetadataExtension]), timeout: @timeout)
        end)

      assert {:ok, <<len::32>>} = :gen_tcp.recv(server, 4, @timeout)
      assert {:ok, our_hs_msg} = :gen_tcp.recv(server, len, @timeout)
      assert <<20, 0, _our_hs::binary>> = our_hs_msg

      assert :ok = :gen_tcp.send(server, frame_payload(<<0>>))

      peer_hs =
        Bento.encode!(%{
          "m" => %{"ut_metadata" => 4},
          "metadata_size" => 1024,
          "v" => "loopback"
        })

      assert :ok = :gen_tcp.send(server, LTEP.extended_message_wire(0, peer_hs))

      assert {:ok, session} = Task.await(exchange, @timeout)
      assert Session.peer_extension_id(session, "ut_metadata") == 4
      assert Session.peer_handshake(session).metadata_size == 1024
    end
  end

  describe "inbound wire framing and dispatch (active TCP)" do
    @tag race_group: :protocol
    test "incomplete length prefix waits for remainder then dispatches" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # Two kernel deliveries (prefix then body) must not dispatch until the frame is complete.
      assert :ok = :gen_tcp.send(server, <<0, 0, 0, 1>>)
      refute_received {:controller, _, _}
      assert :ok = :gen_tcp.send(server, <<0>>)
      assert_receive {:controller, :handle_choke, []}, @timeout
    end

    test "dispatches core protocol messages to Controller" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok =
               :gen_tcp.send(
                 server,
                 IO.iodata_to_binary([
                   frame_payload(<<0>>),
                   frame_payload(<<1>>),
                   frame_payload(<<2>>),
                   frame_payload(<<3>>)
                 ])
               )

      for {fun, args} <- [
            {:handle_choke, []},
            {:handle_unchoke, []},
            {:handle_interested, []},
            {:handle_not_interested, []}
          ] do
        assert_receive {:controller, ^fun, ^args}, @timeout
      end
    end

    test "dispatches transfer and DHT messages to Controller" do
      {client, server, listen, key, sender_pid} = start_sender_pair()
      bitfield = <<0xC0>>

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok =
               :gen_tcp.send(
                 server,
                 IO.iodata_to_binary([
                   frame_payload(<<4, 2::32>>),
                   frame_payload(<<5, bitfield::binary>>),
                   frame_payload(<<6, 0::32, 0::32, 1024::32>>),
                   frame_payload(<<8, 1::32, 0::32, 512::32>>),
                   frame_payload(<<9, 6881::16>>)
                 ])
               )

      assert_receive {:controller, :handle_have, [2]}, @timeout
      assert_receive {:controller, :handle_bitfield, [^bitfield]}, @timeout
      assert_receive {:controller, :handle_request, [0, 0, 1024]}, @timeout
      # cancel is handled inline in Peer.Controller (Uploader.cancel/4), not via cast
      assert_receive {:controller, :handle_port, [6881]}, @timeout
      assert Process.alive?(sender_pid)
    end

    test "dispatches Fast extension and LTEP to Controller" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok =
               :gen_tcp.send(
                 server,
                 IO.iodata_to_binary([
                   frame_payload(<<0x0D, 3::32>>),
                   frame_payload(<<0x0E>>),
                   frame_payload(<<0x0F>>),
                   frame_payload(<<0x10, 0::32, 0::32, 1024::32>>),
                   frame_payload(<<0x11, 1::32>>),
                   Peer.LTEP.extended_message_wire(0, "d2:id1i1ee")
                 ])
               )

      assert_receive {:controller, :handle_suggest_piece, [3]}, @timeout
      assert_receive {:controller, :handle_have_all, []}, @timeout
      assert_receive {:controller, :handle_have_none, []}, @timeout
      assert_receive {:controller, :handle_reject, [0, 0, 1024]}, @timeout
      assert_receive {:controller, :handle_allowed_fast, [1]}, @timeout
      assert_receive {:controller, :handle_extended, [0, "d2:id1i1ee"]}, @timeout
    end

    test "dispatches BEP 52 hash messages to Controller" do
      {client, server, listen, key, sender_pid} = start_sender_pair()
      root = :crypto.strong_rand_bytes(32)
      req = <<root::binary, 0::32, 0::32, 2::32, 1::32>>

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = :gen_tcp.send(server, frame_payload(<<21, req::binary>>))
      assert_receive {:controller, :handle_hash_request, [decoded]}, @timeout
      assert decoded.pieces_root == root
      assert decoded.length == 2

      hashes = :crypto.strong_rand_bytes(96)
      assert :ok = :gen_tcp.send(server, frame_payload(<<22, req::binary, hashes::binary>>))
      assert_receive {:controller, :handle_hashes, [^decoded, ^hashes]}, @timeout

      assert :ok = :gen_tcp.send(server, frame_payload(<<23, req::binary>>))
      assert_receive {:controller, :handle_hash_reject, [^decoded]}, @timeout
    end

    test "unknown wire ids are ignored without stopping the connection" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = :gen_tcp.send(server, frame_payload(<<18, 0, 0>>))
      TestSupport.Sync.sync(sender_pid)
      refute_received {:controller, _, _}

      assert :ok = :gen_tcp.send(server, frame_payload(<<0>>))
      assert_receive {:controller, :handle_choke, []}, @timeout
    end

    test "oversized request length is a protocol error" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      bad_len = @piece_len + 1
      assert :ok = :gen_tcp.send(server, frame_payload(<<6, 0::32, 0::32, bad_len::32>>))

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "oversized ut_metadata frame is rejected from its prefix without buffering its body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      oversized = 2 + Magnet.UtMetadata.max_message_payload_size() + 1
      local_id = UtMetadataExtension.local_id()
      assert :ok = :gen_tcp.send(server, <<oversized::32, 20, local_id>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "oversized unknown LTEP frame is rejected from its prefix without buffering its body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      oversized = Peer.LTEP.max_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 20, 254>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
      refute_received {:controller, :handle_extended, _}
    end

    test "oversized bitfield frame is rejected from its prefix without buffering its body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # Only the 5-byte prefix goes out: the declared body never arrives, so a
      # protocol_error here proves we reject on `len` instead of growing the recv
      # buffer to match it.
      oversized = Peer.Sender.max_bitfield_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 5>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
      refute_received {:controller, :handle_bitfield, _}
    end

    test "bitfield frame at the ceiling still passes framing" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # Guards the other direction: the cap must not clip a real peer's bitfield.
      bitfield = :binary.copy(<<0xFF>>, Peer.Sender.max_bitfield_message_size() - 1)
      assert :ok = :gen_tcp.send(server, frame_payload(<<5, bitfield::binary>>))

      assert_receive {:controller, :handle_bitfield, [^bitfield]}, @timeout
      assert Process.alive?(sender_pid)
    end

    test "oversized piece frame is rejected from its prefix without buffering its body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # 9 = piece id + index::32 + begin::32; the block itself can never exceed the
      # largest block we request (Downloads.piece_max_length/0).
      oversized = 9 + @piece_len + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 7>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
      refute_received {:controller, :handle_piece, _}
    end

    test "wildly oversized bitfield and piece lengths never allocate the declared body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # A 4 GiB declared length: before the cap this grew Sender's buffer unbounded.
      assert :ok = :gen_tcp.send(server, <<0xFFFF_FFFF::32, 5>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout

      {client2, server2, listen2, key2, sender_pid2} = start_sender_pair()
      on_exit(fn -> cleanup(client2, server2, listen2, sender_pid2, key2) end)

      assert :ok = :gen_tcp.send(server2, <<0xFFFF_FFFF::32, 7>>)

      ref2 = Process.monitor(sender_pid2)

      assert_receive {:DOWN, ^ref2, :process, ^sender_pid2, {:shutdown, :protocol_error}},
                     @timeout
    end

    test "oversized unknown wire id is rejected from its prefix without buffering its body" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # id 99 has no per-id cap and never can have one: BEP 3 forward-compat means we
      # must *ignore* unrecognised ids, and the generic take_message/1 clause can only
      # skip a body once it has fully arrived — so a 4 GiB declared length grew the
      # recv buffer toward 4 GiB from a 5-byte prefix. Only that prefix is sent here,
      # so a protocol_error proves the global ceiling rejects on `len` alone.
      refute Peer.Sender.known_wire_id?(99)
      assert :ok = :gen_tcp.send(server, <<0xFFFF_FFFF::32, 99>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
      refute_received {:controller, _, _}
    end

    test "one byte over the global ceiling is rejected for a known-but-uncapped id" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # choke (id 0) is known but has no per-id cap — parse/2 would have called it a
      # protocol error for a >1-byte body, but only after buffering all of it.
      oversized = Peer.Sender.max_wire_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 0>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
      refute_received {:controller, :handle_choke, _}
    end

    test "one byte over the global ceiling is rejected for an unknown id" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # Exact boundary from above: the guard is `len > ceiling`, so ceiling + 1 is the
      # first fatal length.
      oversized = Peer.Sender.max_wire_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 99>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "unknown wire id at a sane length is still ignored per BEP 3 forward-compat" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # The global ceiling bounds SIZE only. An unrecognised id is still just a
      # message from a newer peer, so it must stay non-fatal: skip the frame, keep
      # the connection, and go on parsing whatever follows it in the same stream.
      refute Peer.Sender.known_wire_id?(99)
      assert :ok = :gen_tcp.send(server, frame_payload(<<99, 0, 1, 2, 3>>))
      TestSupport.Sync.sync(sender_pid)
      refute_received {:controller, _, _}

      assert :ok = :gen_tcp.send(server, frame_payload(<<0>>))
      assert_receive {:controller, :handle_choke, []}, @timeout
      assert Process.alive?(sender_pid)
    end

    test "LTEP frame at its own 1 MiB cap still passes the global ceiling" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # The largest frame this client legitimately accepts. The global ceiling is
      # 2 MiB and compares with `>`, so this must survive framing untouched — it is
      # exactly the boundary a ceiling of 1 MiB, or a `>=` comparison, would clip.
      len = Peer.LTEP.max_message_size()
      # 2 = wire id 20 + LTEP extension id; 254 is not ut_metadata's local id, so only
      # the generic LTEP cap applies here.
      payload = :binary.copy(<<0xAB>>, len - 2)
      assert :ok = :gen_tcp.send(server, <<len::32, 20, 254, payload::binary>>)

      assert_receive {:controller, :handle_extended, [254, received]}, @timeout
      assert byte_size(received) == len - 2
      assert received == payload
      assert Process.alive?(sender_pid)
    end

    test "truncated known message body is a protocol error" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # have id + 3 bytes (need 4 for index)
      assert :ok = :gen_tcp.send(server, <<0, 0, 0, 4, 4, 0, 0, 0>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "oversized hashes frame is rejected from its prefix" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      oversized = Peer.HashWire.max_hashes_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 22>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "oversized hash_request frame is rejected from its prefix" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      oversized = 1 + Peer.HashWire.header_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 21>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "oversized hash_reject frame is rejected from its prefix" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      oversized = 1 + Peer.HashWire.header_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32, 23>>)

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "tcp_closed stops Sender cleanly" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      :gen_tcp.close(server)

      ref = Process.monitor(sender_pid)

      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :connection_closed}},
                     @timeout

      flush_tcp_closed()
    end
  end

  describe "frame assembly stall watchdog" do
    test "an incomplete frame starts a watchdog that disconnects the peer once it fires" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # Declares a 10-byte piece body but only 2 bytes ever arrive -- the frame never
      # completes, mirroring a peer trickling a near-ceiling frame in one byte at a time.
      state =
        send_tcp_and_sync_sender(server, client, sender_pid, <<0, 0, 0, 10, 7, 0>>)

      assert is_reference(state.frame_stall_ref)

      down_ref = Process.monitor(sender_pid)
      send(sender_pid, {:frame_stall, state.frame_stall_ref})

      assert_receive {:DOWN, ^down_ref, :process, ^sender_pid, {:shutdown, :frame_stalled}},
                     @timeout
    end

    test "more bytes of the same incomplete frame do not restart its watchdog" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      state =
        send_tcp_and_sync_sender(server, client, sender_pid, <<0, 0, 0, 10, 7, 0>>)

      assert is_reference(state.frame_stall_ref)
      ref = state.frame_stall_ref

      # More dribble for the SAME frame -- still incomplete afterwards.
      state2 = send_tcp_and_sync_sender(server, client, sender_pid, <<0, 0>>)
      assert byte_size(state2.buffer) == byte_size(state.buffer) + 2
      assert state2.frame_stall_ref == ref

      # The watchdog scheduled on the FIRST delivery still fires and disconnects the
      # peer -- the dribble above did not buy it a fresh window.
      down_ref = Process.monitor(sender_pid)
      send(sender_pid, {:frame_stall, ref})

      assert_receive {:DOWN, ^down_ref, :process, ^sender_pid, {:shutdown, :frame_stalled}},
                     @timeout
    end

    test "completing the frame clears its watchdog" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # 5-byte `have` body (id + index::32); only the id and first index byte arrive
      # at first. (Not a `piece` frame here: completing one calls into
      # Peer.Controller.valid_piece_block?/4, which needs a live Torrent.Model this
      # loopback harness never starts.)
      state =
        send_tcp_and_sync_sender(server, client, sender_pid, <<0, 0, 0, 5, 4, 0>>)

      assert is_reference(state.frame_stall_ref)

      assert :ok = :gen_tcp.send(server, <<0, 0, 0>>)
      assert_receive {:controller, :handle_have, [0]}, @timeout

      completed_state = :sys.get_state(sender_pid)
      assert completed_state.frame_stall_ref == nil
      assert completed_state.buffer == <<>>
      assert Process.alive?(sender_pid)
    end

    test "a stale watchdog message is ignored" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      # A ref that can never match state.frame_stall_ref (nil, since nothing is
      # buffered yet) simulates a watchdog belatedly firing for a frame that already
      # completed -- it must not disconnect a healthy connection.
      send(sender_pid, {:frame_stall, make_ref()})

      assert :ok = :gen_tcp.send(server, frame_payload(<<1>>))
      assert_receive {:controller, :handle_unchoke, []}, @timeout
      assert Process.alive?(sender_pid)
    end
  end

  describe "outbound casts produce correct wire bytes" do
    test "single-byte messages and multi-field messages" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.unchoke(key)
      assert wire_message(server) == <<1>>

      assert :ok = Peer.Sender.interested(key)
      assert wire_message(server) == <<2>>

      assert :ok = Peer.Sender.have(key, 7)
      assert wire_message(server) == <<4, 7::32>>

      assert :ok = Peer.Sender.request(key, 0, 512, 2048)
      assert wire_message(server) == <<6, 0::32, 512::32, 2048::32>>

      assert :ok = Peer.Sender.reject(key, 1, 0, 1024)
      assert wire_message(server) == <<0x10, 1::32, 0::32, 1024::32>>

      assert :ok = Peer.Sender.allowed_fast(key, 2)
      assert wire_message(server) == <<0x11, 2::32>>
    end

    test "public wrappers and full BEP 3/6/52 outbound matrix" do
      hash = :crypto.strong_rand_bytes(20)
      id = :crypto.strong_rand_bytes(20)
      {client, server, listen, key, sender_pid} = start_sender_pair(hash, id)
      bitfield = <<0xC0>>
      block = :crypto.strong_rand_bytes(64)
      root = :crypto.strong_rand_bytes(32)

      req = %HashWire{
        pieces_root: root,
        base_layer: 0,
        index: 0,
        length: 2,
        proof_layers: 1
      }

      req_body = HashWire.encode_request(req)
      digests = :crypto.strong_rand_bytes(96)

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      start_bitfield_model(hash, bitfield)

      assert :ok = Peer.Sender.interested(key, false)
      assert wire_message(server) == <<3>>

      assert :ok = Peer.Sender.choke(key)
      assert wire_message(server) == <<0>>

      assert :ok = Peer.Sender.have_all(key)
      assert wire_message(server) == <<0x0E>>

      assert :ok = Peer.Sender.have_none(key)
      assert wire_message(server) == <<0x0F>>

      assert :ok = Peer.Sender.bitfield(key)
      assert wire_message(server) == <<5, bitfield::binary>>

      assert :ok = Peer.Sender.piece(key, 1, 128, block)
      assert wire_message(server) == <<7, 1::32, 128::32, block::binary>>

      assert :ok = Peer.Sender.cancel(key, 2, 0, @piece_len)
      assert wire_message(server) == <<8, 2::32, 0::32, @piece_len::32>>

      assert :ok = Peer.Sender.port(key, 6881)
      assert wire_message(server) == <<9, 6881::16>>

      assert :ok = Peer.Sender.suggest_piece(key, 3)
      assert wire_message(server) == <<0x0D, 3::32>>

      assert :ok = Peer.Sender.hash_request(key, req)
      assert wire_message(server) == <<21, req_body::binary>>

      assert :ok = Peer.Sender.hashes(key, req, digests)
      assert wire_message(server) == <<22, req_body::binary, digests::binary>>

      assert :ok = Peer.Sender.hash_reject(key, req)
      assert wire_message(server) == <<23, req_body::binary>>
    end

    test "send_operations batches choke, not_interested, and cancel" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok =
               Peer.Sender.send_operations(key, [
                 :choke,
                 :not_interested,
                 {:cancel, 0, 0, @piece_len}
               ])

      assert wire_message(server) == <<0>>
      assert wire_message(server) == <<3>>
      assert wire_message(server) == <<8, 0::32, 0::32, @piece_len::32>>
    end
  end

  describe "active/inactive delivery modes" do
    test "deactivate buffers active delivery; socket_recv drains when inactive" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      assert :ok = :gen_tcp.send(server, frame_payload(<<1>>))

      assert {:ok, <<1::32>>} = Peer.Sender.socket_recv(key, 4, @timeout)
      assert {:ok, <<1>>} = Peer.Sender.socket_recv(key, 1, @timeout)

      assert :ok = Peer.Sender.activate(key)
      assert {:error, :active} = Peer.Sender.socket_recv(key, 4, 100)
    end

    test "inactive socket_recv consumes bytes; active mode dispatches to Controller" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      assert :ok = :gen_tcp.send(server, frame_payload(<<2>>))

      assert {:ok, <<0, 0, 0, 1>>} = Peer.Sender.socket_recv(key, 4, @timeout)
      assert {:ok, <<2>>} = Peer.Sender.socket_recv(key, 1, @timeout)
      refute_received {:controller, _, _}

      assert :ok = Peer.Sender.activate(key)
      assert :ok = Peer.Sender.activate(key)
      assert :ok = :gen_tcp.send(server, frame_payload(<<1>>))
      assert_receive {:controller, :handle_unchoke, []}, @timeout
    end

    test "socket_send_raw bypasses message framing" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      raw = <<0xDE, 0xAD, 0xBE, 0xEF>>
      assert :ok = Peer.Sender.socket_send_raw(key, raw)
      assert {:ok, ^raw} = :gen_tcp.recv(server, byte_size(raw), @timeout)
    end

    test "deactivate on an already inactive Sender is idempotent" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      assert :ok = Peer.Sender.deactivate(key)
      assert Process.alive?(sender_pid)
    end

    test "inactive socket_recv stitches partial kernel and follow-up reads" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      assert :ok = :gen_tcp.send(server, <<1, 2, 3, 4>>)

      recv_task =
        Task.async(fn ->
          Peer.Sender.socket_recv(key, 10, @timeout)
        end)

      assert :ok = :gen_tcp.send(server, <<5, 6, 7, 8, 9, 10>>)
      assert {:ok, <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>} = Task.await(recv_task, @timeout)
    end

    test "socket_recv on a stopped Sender returns noproc" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      TestSupport.Sync.safe_stop(sender_pid, 500)
      assert {:error, :noproc} = Peer.Sender.socket_recv(key, 4, 100)
    end
  end

  describe "socket lifecycle and transport error branches" do
    test "activate surfaces setopts errors on a closed socket" do
      {client, server, listen, key, sender_pid} = start_inactive_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      :gen_tcp.close(client)

      assert {:error, activate_reason} = Peer.Sender.activate(key)
      assert is_atom(activate_reason)
      assert :ok = Peer.Sender.deactivate(key)
    end

    test "deactivate returns setopts error after the socket was closed while active" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      :gen_tcp.close(client)

      assert {:error, reason} = Peer.Sender.deactivate(key)
      assert is_atom(reason)
    end

    test "GenServer timeout emits a zero-byte keepalive frame" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      send(sender_pid, :timeout)
      assert {:ok, <<0, 0, 0, 0>>} = :gen_tcp.recv(server, 4, @timeout)
    end

    test "tcp_error stops the Sender with connection_closed" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      ref = Process.monitor(sender_pid)
      send(sender_pid, {:tcp_error, client, :econnreset})

      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :connection_closed}},
                     @timeout
    end

    test "outbound send stops cleanly when the peer socket is closed" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      :gen_tcp.close(client)
      ref = Process.monitor(sender_pid)
      assert :ok = Peer.Sender.unchoke(key)

      assert_receive {:DOWN, ^ref, :process, ^sender_pid, :normal}, @timeout
    end

    test "send_operations stops cleanly when the socket is already closed" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      :gen_tcp.close(server)
      ref = Process.monitor(sender_pid)

      assert :ok =
               Peer.Sender.send_operations(key, [
                 :choke,
                 :not_interested,
                 {:cancel, 0, 0, @piece_len}
               ])

      assert_receive {:DOWN, ^ref, :process, ^sender_pid, :normal}, @timeout
    end

    test "abnormal terminate logs a warning" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      log =
        capture_log([level: :warning], fn ->
          ref = Process.monitor(sender_pid)
          assert :ok = GenServer.stop(sender_pid, {:error, :coverage_test}, 5_000)
          assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:error, :coverage_test}}, @timeout
        end)

      assert log =~ "[peer_sender]"
      assert log =~ "coverage_test"
    end

    test "inactive mode buffers tcp deliveries without dispatching to Controller" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      assert :ok = :gen_tcp.send(server, frame_payload(<<2>>))
      TestSupport.Sync.sync(sender_pid)
      refute_received {:controller, _, _}

      assert {:ok, <<0, 0, 0, 1, 2>>} = Peer.Sender.socket_recv(key, 5, @timeout)
    end
  end

  describe "inbound parse edge cases" do
    test "zero-length wire frame is ignored and connection stays up" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = :gen_tcp.send(server, <<0, 0, 0, 0>>)
      TestSupport.Sync.sync(sender_pid)
      assert Process.alive?(sender_pid)

      assert :ok = :gen_tcp.send(server, frame_payload(<<1>>))
      assert_receive {:controller, :handle_unchoke, []}, @timeout
    end

    test "inbound piece dispatches to Controller with exact index/begin/block" do
      hash = :crypto.strong_rand_bytes(20)
      id = :crypto.strong_rand_bytes(20)
      {client, server, listen, key, sender_pid} = start_sender_pair(hash, id)
      block = :crypto.strong_rand_bytes(128)

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      start_downloads_model(hash, 4)

      assert :ok =
               :gen_tcp.send(
                 server,
                 frame_payload(<<7, 2::32, 64::32, block::binary>>)
               )

      assert_receive {:controller, :handle_piece, [2, 64, 128]}, @timeout
    end

    test "malformed BEP 52 hash_request body is a protocol error" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = :gen_tcp.send(server, frame_payload(<<21, 0::160>>))

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end

    test "malformed BEP 52 hash_reject body is a protocol error" do
      {client, server, listen, key, sender_pid} = start_sender_pair()

      on_exit(fn -> cleanup(client, server, listen, sender_pid, key) end)

      assert :ok = :gen_tcp.send(server, frame_payload(<<23, 0::160>>))

      ref = Process.monitor(sender_pid)
      assert_receive {:DOWN, ^ref, :process, ^sender_pid, {:shutdown, :protocol_error}}, @timeout
    end
  end

  ## helpers -----------------------------------------------------------------

  defp start_sender_pair(hash \\ nil, id \\ nil) do
    {client, server, listen} = loopback_sockets()
    hash = hash || :crypto.strong_rand_bytes(20)
    id = id || :crypto.strong_rand_bytes(20)
    start_sender_pair_with_sockets(client, server, listen, hash, id)
  end

  defp start_inactive_sender_pair do
    {client, server, listen} = loopback_sockets()
    hash = :crypto.strong_rand_bytes(20)
    id = :crypto.strong_rand_bytes(20)
    key = Peer.make_key(hash, id)

    assert {:ok, _capture} = ControllerCapture.start_link(key, self())
    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, client])
    assert :ok = Peer.Transport.controlling_process(client, sender_pid)

    {client, server, listen, key, sender_pid}
  end

  defp start_sender_pair_with_sockets(client, server, listen, hash, id) do
    key = Peer.make_key(hash, id)

    assert {:ok, _capture} = ControllerCapture.start_link(key, self())
    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, client])
    assert :ok = Peer.Transport.controlling_process(client, sender_pid)
    assert :ok = Peer.Sender.activate(key)

    {client, server, listen, key, sender_pid}
  end

  defp start_bitfield_model(hash, bitfield) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "sender-bitfield", "piece length" => @piece_len}},
      left: @piece_len,
      last_index: 0,
      last_piece_length: @piece_len,
      bitfield: bitfield
    }

    {:ok, model} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model, 500)
    end)

    :ok
  end

  defp start_downloads_model(hash, pieces_count) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "sender-piece", "piece length" => @piece_len}},
      left: pieces_count * @piece_len,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(pieces_count)
    }

    {:ok, model} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model, 500)
    end)

    :ok
  end

  defp loopback_sockets do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    spawn_loopback_acceptor(listen, self(), @timeout)

    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)

    await_loopback_server(client, listen, @timeout)
  end

  defp spawn_loopback_acceptor(listen, parent, timeout) do
    spawn(fn ->
      case :gen_tcp.accept(listen, timeout) do
        {:ok, server} ->
          _ = :gen_tcp.controlling_process(server, parent)
          send(parent, {:loopback_server, server})

        error ->
          send(parent, {:loopback_accept_error, error})
      end
    end)
  end

  defp await_loopback_server(client, listen, timeout) do
    receive do
      {:loopback_server, server} ->
        {client, server, listen}

      {:loopback_accept_error, error} ->
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        flunk("accept failed: #{inspect(error)}")
    after
      timeout -> flunk("accept timed out")
    end
  end

  defp frame_payload(body) when is_binary(body) do
    <<byte_size(body)::32, body::binary>>
  end

  defp send_tcp_and_sync_sender(server, client, sender_pid, data) do
    1 = :erlang.trace(sender_pid, true, [:receive])
    assert :ok = :gen_tcp.send(server, data)
    assert_receive {:trace, ^sender_pid, :receive, {:tcp, ^client, ^data}}, @timeout
    _ = :erlang.trace(sender_pid, false, [:receive])
    :sys.get_state(sender_pid)
  end

  defp wire_message(server) do
    assert {:ok, <<len::32>>} = :gen_tcp.recv(server, 4, @timeout)
    assert {:ok, body} = :gen_tcp.recv(server, len, @timeout)
    body
  end

  defp flush_tcp_closed do
    receive do
      {:tcp_closed, _} -> flush_tcp_closed()
    after
      0 -> :ok
    end
  end

  defp cleanup(client, server, listen, sender_pid, key) do
    _ = Peer.Sender.deactivate(key)

    for {sock, close} <- [
          {client, &:gen_tcp.close/1},
          {server, &:gen_tcp.close/1},
          {listen, &:gen_tcp.close/1}
        ] do
      try do
        if is_port(sock), do: close.(sock)
      catch
        :error, _ -> :ok
      end
    end

    for pid <- [sender_pid, ControllerCapture.whereis(key)] do
      TestSupport.Sync.safe_stop(pid, 500)
    end

    flush_exit_messages()
  end

  defp flush_exit_messages do
    receive do
      {:EXIT, _, _} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end
end

defmodule PeerSenderLoopbackTest do
  # Loopback TCP + Registry-backed Sender/Controller stubs; not async-safe.
  use ExUnit.Case, async: false

  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias PeerWireTest.ControllerCapture

  @piece_len Torrent.Downloads.piece_max_length()
  @timeout 5_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)
    :ok
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
  end

  ## helpers -----------------------------------------------------------------

  defp start_sender_pair do
    {client, server, listen} = loopback_sockets()
    hash = :crypto.strong_rand_bytes(20)
    id = :crypto.strong_rand_bytes(20)
    key = Peer.make_key(hash, id)

    assert {:ok, _capture} = ControllerCapture.start_link(key, self())
    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, client])
    assert :ok = Peer.Transport.controlling_process(client, sender_pid)
    assert :ok = Peer.Sender.activate(key)

    {client, server, listen, key, sender_pid}
  end

  defp loopback_sockets do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn(fn ->
      case :gen_tcp.accept(listen, @timeout) do
        {:ok, server} ->
          _ = :gen_tcp.controlling_process(server, parent)
          send(parent, {:loopback_server, server})

        error ->
          send(parent, {:loopback_accept_error, error})
      end
    end)

    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)

    receive do
      {:loopback_server, server} ->
        {client, server, listen}

      {:loopback_accept_error, error} ->
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        flunk("accept failed: #{inspect(error)}")
    after
      @timeout -> flunk("accept timed out")
    end
  end

  defp frame_payload(body) when is_binary(body) do
    <<byte_size(body)::32, body::binary>>
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

defmodule PeerWireTest.ControllerCapture do
  @moduledoc false
  use GenServer

  def start_link(key, test_pid) do
    GenServer.start_link(__MODULE__, {key, test_pid},
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  def whereis(key), do: GenServer.whereis({:via, Registry, {Registry, {key, Peer.Controller}}})

  @impl true
  def init({key, test_pid}), do: {:ok, {key, test_pid}}

  @impl true
  def handle_cast({fun, args}, {key, test_pid}) when is_atom(fun) and is_list(args) do
    send(test_pid, {:controller, fun, args})
    {:noreply, {key, test_pid}}
  end
end

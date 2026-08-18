defmodule LoopbackSourceBindTest do
  @moduledoc """
  BEP 7 makes us bind the tracker connection to the address we announce, so the
  tracker records the source it actually sees. That bind is only valid when the
  bound address can reach the destination.

  A loopback destination cannot be reached from it. `127.0.0.1`/`::1` route out
  of the loopback interface, and that interface owns no LAN or global address,
  so a socket bound to `192.168.x.y` has no path to them. Windows applies the
  strong host model (its default since Vista) and refuses the `connect`/`sendto`
  outright with `:eaddrnotavail`; macOS/BSD use the weak host model and quietly
  emit the packet with a source address the outgoing interface does not own.
  The engine must not depend on the lenient behaviour, so the source bind is
  dropped for loopback destinations on every platform.
  """
  use ExUnit.Case, async: false

  alias Tracker.Response

  @hash :crypto.strong_rand_bytes(20)

  describe "Acceptor.loopback_ip?/1" do
    test "covers all of 127.0.0.0/8 and ::1, and nothing else" do
      assert Acceptor.loopback_ip?({127, 0, 0, 1})
      assert Acceptor.loopback_ip?({127, 13, 4, 9})
      assert Acceptor.loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1})

      refute Acceptor.loopback_ip?({192, 168, 1, 7})
      refute Acceptor.loopback_ip?({0, 0, 0, 0})
      refute Acceptor.loopback_ip?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 7})
      # ::ffff:127.0.0.1 is an IPv4-mapped address, not the IPv6 loopback: it
      # is only ever produced on a dual-stack socket, whose route follows the
      # embedded IPv4 address.
      refute Acceptor.loopback_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
    end
  end

  describe "HTTP announce source selection" do
    test "a tracker that resolves only to loopback drops the source bind" do
      assert Tracker.loopback_tracker_for_test("http://127.0.0.1:6969/announce")
      assert Tracker.loopback_tracker_for_test("http://[::1]:6969/announce")
      assert Tracker.loopback_tracker_for_test("http://localhost:6969/announce")
    end

    test "a routable or unresolvable tracker keeps the BEP 7 source bind" do
      refute Tracker.loopback_tracker_for_test("http://192.0.2.10:6969/announce")
      refute Tracker.loopback_tracker_for_test("http://[2001:db8::7]:6969/announce")
      # No answer means no evidence that loopback is the destination; keep the
      # announce honest rather than silently widening it.
      refute Tracker.loopback_tracker_for_test("http://tracker.invalid.example:6969/announce")
    end

    test "a nil source asks Hackney for the family only, never for a bind" do
      v4 = Tracker.http_hackney_opts_for_test(:inet, nil)
      assert v4[:pool] == false
      assert v4[:connect_options] == [:inet]
      refute Enum.any?(v4[:connect_options], &match?({:ip, _}, &1))

      v6 = Tracker.http_hackney_opts_for_test(:inet6, nil)
      assert v6[:pool] == false
      assert v6[:connect_options] == [:inet6]
      refute Enum.any?(v6[:connect_options], &match?({:ip, _}, &1))
    end

    test "a routable source still binds, so BEP 7 keeps working" do
      assert Tracker.http_hackney_opts_for_test(:inet, {192, 0, 2, 7})[:connect_options] ==
               [{:ip, {192, 0, 2, 7}}]
    end
  end

  describe "announces to a loopback tracker complete" do
    setup do
      {:ok, _} = Application.ensure_all_started(:elixir_torrent)
      :ok
    end

    test "HTTP announce to 127.0.0.1 reaches the tracker" do
      body = Bento.encode!(%{"interval" => 1_800, "peers" => <<>>})
      port = start_http_tracker(body)

      assert %Response{} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce",
                 @hash,
                 [uploaded: 0, downloaded: 0, left: 1, event: Torrent.started()],
                 http_timeout_ms: 5_000
               )
    end

    test "UDP announce to 127.0.0.1 completes the BEP 15 connect/announce pair" do
      {port, server} = start_udp_tracker()
      on_exit(fn -> :gen_udp.close(server) end)

      assert %Response{} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 uploaded: 0,
                 downloaded: 0,
                 left: 1,
                 event: Torrent.started()
               )
    end
  end

  ## helpers -----------------------------------------------------------------

  defp start_http_tracker(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    parent = self()

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        response =
          "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body

        :ok = :gen_tcp.send(socket, response)
        # Wait for the client's own close before closing, so the response is
        # never discarded by an abortive close (see the moduledoc's host model
        # note: Windows resets a socket closed with unread data queued).
        _ = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        send(parent, :http_tracker_done)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  # Minimal BEP 15 tracker: answer `connect` with the magic transaction echo,
  # then answer `announce` with an empty peer list.
  defp start_udp_tracker do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    responder = spawn_link(fn -> udp_tracker_loop(socket) end)
    :ok = :gen_udp.controlling_process(socket, responder)
    {port, socket}
  end

  defp udp_tracker_loop(socket) do
    receive do
      {:udp, ^socket, ip, from_port, <<0x41727101980::64, 0::32, transaction::binary-size(4)>>} ->
        :gen_udp.send(socket, ip, from_port, <<0::32, transaction::binary, 7::64>>)
        udp_tracker_loop(socket)

      {:udp, ^socket, ip, from_port, <<7::64, 1::32, transaction::binary-size(4), _rest::binary>>} ->
        :gen_udp.send(
          socket,
          ip,
          from_port,
          <<1::32, transaction::binary, 1_800::32, 0::32, 0::32>>
        )

        udp_tracker_loop(socket)

      {:udp, ^socket, _ip, _port, _other} ->
        udp_tracker_loop(socket)
    end
  end
end

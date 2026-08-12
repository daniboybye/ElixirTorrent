defmodule Cycle3TrackerWireCoverageTest do
  @moduledoc """
  Coverage for tracker announce edge cases and for the uTP shutdown signals a
  peer connection can receive.

  Tracker responses are attacker-controlled data from a third party we did not
  choose, so a field with the wrong type has to be dropped rather than crash the
  announce loop that every torrent depends on. And an announce must not be sent
  at all while the torrent's `Model` has not published its counters — sending
  zeroed `uploaded`/`downloaded` would corrupt the tracker's ratio accounting.
  """
  use ExUnit.Case, async: false

  alias Tracker.{Error, Response}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "Tracker.request!/4 with :auto stats" do
    test "defers the announce while the torrent has no Model" do
      hash = :crypto.strong_rand_bytes(20)
      port = start_http_tracker(Bento.encode!(%{"interval" => 1_800, "peers" => <<>>}))

      assert nil == Tracker.request!("http://127.0.0.1:#{port}/announce", hash, :auto)
    end

    test "a UDP tracker whose host does not resolve is never retried" do
      hash = :crypto.strong_rand_bytes(20)

      assert %Error{reason: {:dns, _, _}, retry_in: "never"} =
               Tracker.request!(
                 "udp://tracker.invalid.elixirtorrent.test:6969/announce",
                 hash,
                 uploaded: 0,
                 downloaded: 0,
                 left: 16_384,
                 event: Torrent.started()
               )
    end
  end

  describe "Tracker HTTP announce responses" do
    test "an announce URL that already ends in ? keeps a single query separator" do
      hash = :crypto.strong_rand_bytes(20)
      test_pid = self()

      port =
        start_http_tracker(
          Bento.encode!(%{"interval" => 1_800, "peers" => <<>>}),
          fn request -> send(test_pid, {:request_line, request_line(request)}) end
        )

      assert %Response{} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce?",
                 hash,
                 [uploaded: 0, downloaded: 0, left: 1, event: Torrent.started()],
                 http_timeout_ms: 5_000
               )

      assert_receive {:request_line, line}, 5_000
      refute line =~ "??"
      refute line =~ "?&"
    end

    test "peers6 with the wrong type and peer dicts with bad addresses are dropped" do
      hash = :crypto.strong_rand_bytes(20)

      body =
        Bento.encode!(%{
          "interval" => 1_800,
          # BEP 7 says peers6 is a compact binary (or a dict list); an integer
          # is neither and must not take the announce down.
          "peers6" => 42,
          "peers" => [
            %{"peer id" => "x", "port" => 6881, "ip" => "not-an-ip"},
            %{"peer id" => "y", "port" => 6882, "ip" => "192.0.2.11"}
          ]
        })

      port = start_http_tracker(body)

      assert %Response{peers: peers} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce",
                 hash,
                 [uploaded: 0, downloaded: 0, left: 1, event: Torrent.started()],
                 http_timeout_ms: 5_000
               )

      assert peers == [%Peer{id: "y", port: 6882, ip: {192, 0, 2, 11}}]
    end
  end

  describe "Peer.Sender uTP shutdown signals" do
    test "a closed or failed uTP connection stops the sender" do
      assert {:stop, {:shutdown, :connection_closed}, :state} =
               Peer.Sender.handle_info({:utp_closed, make_ref()}, :state)

      assert {:stop, {:shutdown, :connection_closed}, :state} =
               Peer.Sender.handle_info({:utp_error, make_ref(), :econnreset}, :state)
    end
  end

  describe "Torrents.remove/2" do
    test "removing an unknown torrent reports it rather than deleting anything" do
      assert {:error, :not_found} =
               Torrents.remove(:crypto.strong_rand_bytes(20), delete_data: false)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp request_line(request) do
    request
    |> String.split("\r\n")
    |> List.first()
  end

  defp start_http_tracker(body, on_request \\ fn _ -> :ok end) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> serve(listen, body, on_request) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp serve(listen, body, on_request) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> respond(socket, body, on_request) end)
        serve(listen, body, on_request)

      {:error, _} ->
        :ok
    end
  end

  defp respond(socket, body, on_request) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, request} ->
        on_request.(request)

        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\n",
          "Content-Type: text/plain\r\n",
          "Content-Length: #{byte_size(body)}\r\n",
          "Connection: close\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end
end

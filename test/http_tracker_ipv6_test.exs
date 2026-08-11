defmodule HTTPTrackerIPv6Test do
  use ExUnit.Case, async: false

  alias Tracker.UDP

  @hash :crypto.strong_rand_bytes(20)
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "BEP 7 HTTP announce query" do
    test "uses the connection source instead of discouraged ip parameters" do
      query =
        Tracker.build_http_announce_query(@hash, 0, 0, 16_384, Torrent.started())

      assert Map.has_key?(query, "info_hash")
      assert Map.has_key?(query, "port")
      refute Map.has_key?(query, "ip")
      refute Map.has_key?(query, "ipv6")
    end

    test "binds Hackney's IPv6 socket to the selected announce address" do
      source_ip = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}
      opts = Tracker.http_hackney_opts_for_test(:inet6, source_ip)

      assert opts[:pool] == false
      assert opts[:connect_options] == [:inet6, {:ip, source_ip}]
    end

    test "IPv6 announce reaches the tracker from the selected source" do
      parent = self()
      {port, server_pid} = start_ipv6_http_tracker(parent)

      result =
        with_primary_ipv6(@loopback_v6, fn ->
          Tracker.request!(
            "http://[::1]:#{port}/announce",
            @hash,
            [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()],
            http_timeout_ms: 5_000
          )
        end)

      assert %Tracker.Response{} = result
      assert_receive {:http_announce_source, @loopback_v6, target}, 5_000

      query =
        target
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      refute Map.has_key?(query, "ip")
      refute Map.has_key?(query, "ipv6")

      refute Process.alive?(server_pid)
    end
  end

  describe "BEP 7 peers6 parsing" do
    test "to_peers_v6 decodes 18-byte compact IPv6 peer records" do
      bin =
        <<0x26, 0x02, 0x00, 0x2D, 0x40, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x42, 0x1A, 0xE1>>

      peers = UDP.parse_compact_peers(bin, :inet6)
      assert length(peers) == 1
      assert hd(peers).port == 6881
      assert tuple_size(hd(peers).ip) == 8
    end
  end

  describe "BEP 32 DHT compact IPv6 peers" do
    test "decode_ipv6_peers parses 18-byte values entries" do
      bin =
        <<0x26, 0x02, 0x00, 0x2D, 0x40, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0x42, 0x1A, 0xE1>>

      peers = DHT.Compact.decode_ipv6_peers(bin)
      assert length(peers) == 1
      assert hd(peers).port == 6881
    end
  end

  defp start_ipv6_http_tracker(parent) do
    pid =
      spawn_link(fn ->
        {listen, port} = open_ipv6_http_listener()
        send(parent, {:http_tracker_ready, port, self()})
        serve_ipv6_http_tracker_request(listen, parent)
      end)

    receive do
      {:http_tracker_ready, port, ^pid} -> {port, pid}
    after
      5_000 -> flunk("IPv6 HTTP tracker failed to start")
    end
  end

  defp open_ipv6_http_listener do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        :inet6,
        active: false,
        reuseaddr: true,
        ipv6_v6only: true,
        ip: @loopback_v6
      ])

    {:ok, port} = :inet.port(listen)
    {listen, port}
  end

  defp serve_ipv6_http_tracker_request(listen, parent) do
    {:ok, socket} = :gen_tcp.accept(listen, 5_000)
    {:ok, {source_ip, _source_port}} = :inet.peername(socket)
    {:ok, request} = recv_http_headers(socket, "")
    [request_line | _] = String.split(request, "\r\n")
    ["GET", target, _version] = String.split(request_line, " ")
    send(parent, {:http_announce_source, source_ip, target})

    body = Bento.encode!(%{"interval" => 1_200, "peers" => <<>>})

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

    :gen_tcp.close(socket)
    :gen_tcp.close(listen)
  end

  defp recv_http_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> recv_http_headers(socket, acc <> chunk)
        error -> error
      end
    end
  end

  defp with_primary_ipv6(ip, fun) do
    key = Acceptor.ip_cache_key()
    previous = :persistent_term.get(key, :missing)
    cache = %{inet: nil, inet6: ip, inet6_all: [ip], multicast_interfaces: %{inet: [], inet6: []}}
    cache_pid = Process.whereis(Acceptor.IpCache)

    if cache_pid, do: :sys.suspend(cache_pid)
    :persistent_term.put(key, cache)

    try do
      fun.()
    after
      case previous do
        :missing -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end

      if cache_pid, do: TestSupport.Sync.safe_resume(cache_pid)
    end
  end
end

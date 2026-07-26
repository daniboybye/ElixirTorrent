defmodule TrackerUDPLoopbackTest do
  use ExUnit.Case, async: false

  alias Tracker.UDP

  @protocol_id UDP.protocol_id()
  @hash :crypto.strong_rand_bytes(20)
  @connection_id <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE>>
  @fast_fail [max_udp_attempts: 0, http_timeout_ms: 5_000]
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "BEP 15 loopback connect + announce + scrape" do
    test "udp_connect and request! against local UDP tracker" do
      peers = <<127, 0, 0, 1, 6881::16, 10, 0, 0, 2, 8080::16>>
      {port, server_pid} = start_bep15_server(announce_peers: peers)

      on_exit(fn ->
        Process.exit(server_pid, :kill)
      end)

      stats = [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()]

      assert %Tracker.Response{interval: 1200, complete: 10, incomplete: 5, peers: decoded} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 stats,
                 @fast_fail
               )

      assert length(decoded) == 2
    end

    test "udp_scrape returns stats map for loopback tracker" do
      hash = @hash
      {port, server_pid} = start_bep15_server(scrape_stats: {10, 20, 30})

      on_exit(fn ->
        Process.exit(server_pid, :kill)
      end)

      {:ok, socket} =
        :gen_udp.open(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_udp.close(socket) end)

      assert %{^hash => %{seeders: 10, leechers: 30, completed: 20}} =
               Tracker.udp_scrape(socket, {127, 0, 0, 1}, port, [hash], @fast_fail)
    end

    test "Tracker.scrape/2 uses UDP loopback endpoint" do
      {port, server_pid} = start_bep15_server(scrape_stats: {1, 2, 3})

      on_exit(fn ->
        Process.exit(server_pid, :kill)
      end)

      assert %{seeders: 1, leechers: 3, completed: 2} =
               Tracker.scrape("udp://127.0.0.1:#{port}/announce", @hash)
    end

    test "udp backoff retry succeeds when loopback answers on second attempt" do
      {port, server_pid} =
        start_bep15_server(
          connect_delay_ms: 0,
          drop_first_connect_response: true,
          announce_peers: <<>>
        )

      on_exit(fn ->
        Process.exit(server_pid, :kill)
      end)

      Application.put_env(:elixir_torrent, :udp_backoff_ms, fn _attempt -> 20 end)

      on_exit(fn -> Application.delete_env(:elixir_torrent, :udp_backoff_ms) end)

      {:ok, socket} =
        :gen_udp.open(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_udp.close(socket) end)

      assert <<_::64>> = Tracker.udp_connect(socket, {127, 0, 0, 1}, port, max_udp_attempts: 1)
    end

    test "long announce retry reconnects after the connection-id cache expires" do
      {port, server_pid} = start_connection_id_retry_server(:expired, self())

      on_exit(fn ->
        Process.exit(server_pid, :kill)
      end)

      Application.put_env(:elixir_torrent, :udp_backoff_ms, fn _attempt -> 20 end)
      on_exit(fn -> Application.delete_env(:elixir_torrent, :udp_backoff_ms) end)

      assert %Tracker.Response{} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 uploaded: 0,
                 downloaded: 0,
                 left: 16_384,
                 event: Torrent.started()
               )

      assert_receive {:retry_server, :connect, <<1::64>>}
      assert_receive {:retry_server, :announce, <<1::64>>, 1}
      assert_receive {:retry_server, :connect, <<2::64>>}
      assert_receive {:retry_server, :announce, <<2::64>>, 2}
    end

    test "long announce retry reuses a connection id while it remains valid" do
      {port, server_pid} = start_connection_id_retry_server(:valid, self())

      on_exit(fn ->
        Process.exit(server_pid, :kill)
      end)

      Application.put_env(:elixir_torrent, :udp_backoff_ms, fn _attempt -> 20 end)
      on_exit(fn -> Application.delete_env(:elixir_torrent, :udp_backoff_ms) end)

      assert %Tracker.Response{} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 uploaded: 0,
                 downloaded: 0,
                 left: 16_384,
                 event: Torrent.started()
               )

      assert_receive {:retry_server, :connect, <<1::64>>}
      assert_receive {:retry_server, :announce, <<1::64>>, 1}
      assert_receive {:retry_server, :announce, <<1::64>>, 2}
      refute_receive {:retry_server, :connect, <<2::64>>}, 50
    end

    test "IPv6 announce socket is bound to the selected source address" do
      assert {:ok, probe_socket} = Acceptor.open_udp(:inet6, @loopback_v6)
      assert {:ok, {@loopback_v6, _port}} = :inet.sockname(probe_socket)
      :gen_udp.close(probe_socket)

      {port, server_pid} =
        start_bep15_server(
          family: :inet6,
          observer: self(),
          announce_peers: <<>>
        )

      on_exit(fn ->
        Process.exit(server_pid, :kill)
      end)

      result =
        with_primary_ipv6(@loopback_v6, fn ->
          Tracker.request!(
            "udp://[::1]:#{port}/announce",
            @hash,
            [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()],
            @fast_fail
          )
        end)

      assert %Tracker.Response{} = result
      assert_receive {:bep15_source, 1, @loopback_v6}, 5_000
    end
  end

  describe "encode_udp_announce_for_test/5" do
    test "uses zero ip_field for IPv6 announces per BEP 15" do
      tid = <<1, 2, 3, 4>>
      stats = {0, 0, 100, 2}

      packet =
        Tracker.encode_udp_announce_for_test(@connection_id, tid, @hash, stats, :inet6)
        |> IO.iodata_to_binary()

      assert byte_size(packet) == 98
      # BEP 15 IPv6 clients send ip_field = 0 (4 bytes at offset 84..87).
      <<_::binary-size(84), 0, 0, 0, 0, _rest::binary>> = packet
    end
  end

  defp start_connection_id_retry_server(cache_state, observer) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} =
          :gen_udp.open(0, [
            :binary,
            :inet,
            active: true,
            reuseaddr: true,
            ip: {127, 0, 0, 1}
          ])

        {:ok, port} = :inet.port(socket)
        send(parent, {:retry_server_ready, port})
        connection_id_retry_loop(socket, port, cache_state, observer, 0, 0)
      end)

    receive do
      {:retry_server_ready, port} -> {port, pid}
    after
      5_000 -> flunk("BEP15 retry server failed to start")
    end
  end

  defp connection_id_retry_loop(
         socket,
         tracker_port,
         cache_state,
         observer,
         connect_count,
         announce_count
       ) do
    protocol_id = @protocol_id

    receive do
      {:udp, ^socket, ip, client_port,
       <<^protocol_id::binary-size(8), 0::32, tid::binary-size(4)>>} ->
        next_connect_count = connect_count + 1
        connection_id = <<next_connect_count::64>>
        send(observer, {:retry_server, :connect, connection_id})

        :ok =
          :gen_udp.send(
            socket,
            ip,
            client_port,
            <<0::32, tid::binary, connection_id::binary>>
          )

        connection_id_retry_loop(
          socket,
          tracker_port,
          cache_state,
          observer,
          next_connect_count,
          announce_count
        )

      {:udp, ^socket, ip, client_port,
       <<connection_id::binary-size(8), 1::32, tid::binary-size(4), _rest::binary>>} ->
        next_announce_count = announce_count + 1
        send(observer, {:retry_server, :announce, connection_id, next_announce_count})

        if next_announce_count == 1 and cache_state == :expired do
          key = {{127, 0, 0, 1}, tracker_port, client_port}
          send(PeerDiscovery.ConnectionIds, {:timeout, key})
          :sys.get_state(PeerDiscovery.ConnectionIds)
        end

        if next_announce_count > 1 do
          :ok =
            :gen_udp.send(
              socket,
              ip,
              client_port,
              <<1::32, tid::binary, 1200::32, 5::32, 10::32>>
            )
        end

        connection_id_retry_loop(
          socket,
          tracker_port,
          cache_state,
          observer,
          connect_count,
          next_announce_count
        )
    end
  end

  defp start_bep15_server(opts) do
    parent = self()
    family = Keyword.get(opts, :family, :inet)
    bind_ip = if family == :inet6, do: @loopback_v6, else: {127, 0, 0, 1}

    spawn_link(fn ->
      {:ok, socket} =
        :gen_udp.open(0, [:binary, family, active: true, reuseaddr: true, ip: bind_ip])

      {:ok, port} = :inet.port(socket)
      send(parent, {:bep15_ready, port, self()})
      bep15_loop(socket, Map.new(opts))
    end)

    receive do
      {:bep15_ready, port, server_pid} -> {port, server_pid}
    after
      5_000 -> flunk("BEP15 loopback server failed to start")
    end
  end

  defp bep15_loop(socket, state) do
    receive do
      {:udp, ^socket, ip, port, data} ->
        if observer = state[:observer] do
          <<_connection_id::binary-size(8), action::32, _rest::binary>> = data
          send(observer, {:bep15_source, action, ip})
        end

        response = handle_bep15(data, state)
        if response, do: :gen_udp.send(socket, ip, port, response)

        bep15_loop(
          socket,
          Map.update(state, :drop_first_connect_response, false, fn _ -> false end)
        )
    end
  end

  defp handle_bep15(data, state) do
    protocol_id = @protocol_id

    if match_connect?(data, protocol_id) do
      bep15_connect_response(data, protocol_id, state)
    else
      bep15_action_response(data, state)
    end
  end

  defp bep15_connect_response(data, protocol_id, state) do
    <<^protocol_id::binary-size(8), 0::32, tid::binary-size(4)>> = data

    if state[:drop_first_connect_response] do
      nil
    else
      <<0::32, tid::binary, @connection_id::binary>>
    end
  end

  defp bep15_action_response(data, state) do
    <<_connection_id::binary-size(8), action::32, tid::binary-size(4), rest::binary>> = data

    case action do
      1 ->
        peers = Map.get(state, :announce_peers, <<>>)
        <<1::32, tid::binary, 1200::32, 5::32, 10::32, peers::binary>>

      2 ->
        {seeders, completed, leechers} = Map.get(state, :scrape_stats, {0, 0, 0})
        hash_count = div(byte_size(rest), 20)

        stats =
          for _ <- 1..hash_count do
            <<seeders::32, completed::32, leechers::32>>
          end

        <<2::32, tid::binary, IO.iodata_to_binary(stats)::binary>>

      3 ->
        <<3::32, tid::binary, "tracker error">>

      _ ->
        nil
    end
  end

  defp match_connect?(data, protocol_id) do
    case data do
      <<^protocol_id::binary-size(8), 0::32, _::binary-size(4)>> -> true
      _ -> false
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

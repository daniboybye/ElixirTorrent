defmodule Bep7MultihomedAnnounceTest do
  @moduledoc """
  BEP 7 multi-homed announce: a tracker announce leaves from every eligible
  local address, not only from the primary one per family.

  The address discovery is checked against synthetic `getifaddrs` lists, the
  concurrency/abandon rules of `Tracker.Fanout` against fake jobs, and the
  whole path against loopback BEP 15 and HTTP trackers. Those last ones stand
  in for a multi-homed host with `127.0.0.1`, `127.0.0.2` and `127.0.0.3` —
  Linux routes all of `127.0.0.0/8` to the loopback interface; a host that
  cannot bind the aliases (macOS without `ifconfig lo0 alias`) skips them.
  """
  use ExUnit.Case, async: false

  alias Tracker.{Error, Fanout, Response, UDP}

  @hash :crypto.strong_rand_bytes(20)
  @protocol_id UDP.protocol_id()
  @connection_id <<0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE>>
  @fast_fail [max_udp_attempts: 0, http_timeout_ms: 5_000]
  @started [uploaded: 0, downloaded: 0, left: 16_384, event: 2]

  @lo1 {127, 0, 0, 1}
  @lo2 {127, 0, 0, 2}
  @lo3 {127, 0, 0, 3}

  @loopback_aliases (case :gen_udp.open(0, [:binary, ip: {127, 0, 0, 2}]) do
                       {:ok, socket} ->
                         :gen_udp.close(socket)
                         true

                       {:error, _reason} ->
                         false
                     end)
  @alias_skip if @loopback_aliases, do: false, else: "127.0.0.2 is not bindable on this host"

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "Acceptor.announce_sources_from/3 — which addresses announce" do
    test "one interface with several IPv6 addresses announces only the primary" do
      ifs = [
        {~c"lo", [flags: [:up, :running, :loopback], addr: @lo1, addr: {0, 0, 0, 0, 0, 0, 0, 1}]},
        {~c"en0",
         [
           flags: [:up, :running, :multicast],
           addr: {192, 168, 1, 15},
           addr: {0x2A01, 0x5A8, 0x302, 0xD612, 1, 2, 3, 4},
           # privacy-extension temporaries on the same NIC
           addr: {0x2A01, 0x5A8, 0x302, 0xD612, 5, 6, 7, 8},
           addr: {0x2A01, 0x5A8, 0x302, 0xD612, 9, 9, 9, 9}
         ]}
      ]

      snapshot = Acceptor.compute_all_global_ips({:ok, ifs})

      assert snapshot.announce_sources == %{
               inet: [{192, 168, 1, 15}],
               inet6: [{0x2A01, 0x5A8, 0x302, 0xD612, 1, 2, 3, 4}]
             }
    end

    test "a second NIC and a VPN add one source each, primary first" do
      gua_wifi = {0x2001, 0xDB8, 0xAAAA, 0, 0, 0, 0, 0x10}
      gua_vpn = {0x2001, 0xDB8, 0xBBBB, 0, 0, 0, 0, 0x20}

      ifs = [
        {~c"lo", [flags: [:up, :running, :loopback], addr: @lo1]},
        {~c"eth0", [flags: [:up, :running, :multicast], addr: {192, 168, 1, 15}]},
        {~c"wlan0",
         [
           flags: [:up, :running, :multicast],
           addr: {10, 0, 0, 7},
           addr: {0xFE80, 0, 0, 0, 1, 2, 3, 4},
           addr: gua_wifi
         ]},
        {~c"tun0", [flags: [:up, :running, :pointtopoint], addr: {100, 64, 3, 9}, addr: gua_vpn]},
        {~c"eth1", [flags: [:broadcast], addr: {172, 16, 0, 9}]}
      ]

      snapshot = Acceptor.compute_all_global_ips({:ok, ifs})

      assert snapshot.announce_sources.inet == [{192, 168, 1, 15}, {10, 0, 0, 7}, {100, 64, 3, 9}]
      assert snapshot.announce_sources.inet6 == [gua_wifi, gua_vpn]

      assert snapshot.inet_all == [
               {192, 168, 1, 15},
               {10, 0, 0, 7},
               {100, 64, 3, 9},
               {172, 16, 0, 9}
             ]
    end

    test "an added IPv6 source must be one a public tracker can answer" do
      primary_ula = {0xFD00, 0, 0, 0, 0, 0, 0, 1}

      ifs = [
        {~c"eth0", [flags: [:up], addr: primary_ula]},
        {~c"eth1", [flags: [:up], addr: {0xFD12, 0x3456, 0, 0, 0, 0, 0, 2}]},
        {~c"eth2", [flags: [:up], addr: {0xFEC0, 0, 0, 0, 0, 0, 0, 3}]},
        {~c"eth3", [flags: [:up], addr: {0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}]},
        {~c"eth4", [flags: [:up], addr: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 4}]}
      ]

      # The primary stays whatever every other subsystem advertises.
      assert %{inet: [], inet6: [^primary_ula, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 4}]} =
               Acceptor.announce_sources_from(ifs, nil, primary_ula)
    end

    test "no address of a family means no source of it, and getifaddrs failure means none" do
      ifs = [{~c"eth0", [flags: [:up], addr: {192, 168, 1, 15}]}]

      assert %{inet: [{192, 168, 1, 15}], inet6: []} =
               Acceptor.announce_sources_from(ifs, {192, 168, 1, 15}, nil)

      assert %{announce_sources: %{inet: [], inet6: []}, inet_all: []} =
               Acceptor.compute_all_global_ips({:error, :eperm})
    end
  end

  describe "Acceptor.announce_sources/0 — snapshot, limits and interface changes" do
    test "reads the snapshot, follows interface changes and honours the cap" do
      with_snapshot(snapshot([@lo1, @lo2, @lo3, {10, 0, 0, 4}, {10, 0, 0, 5}]), fn ->
        # default cap: four per family
        assert Acceptor.announce_sources().inet == [@lo1, @lo2, @lo3, {10, 0, 0, 4}]

        with_tracker_env([max_sources_per_family: 2], fn ->
          assert Acceptor.announce_sources().inet == [@lo1, @lo2]
        end)

        with_tracker_env([multihomed_announce: false], fn ->
          assert Acceptor.announce_sources().inet == [@lo1]
        end)
      end)

      # An interface went away between two refreshes.
      with_snapshot(snapshot([@lo1]), fn ->
        assert Acceptor.announce_sources().inet == [@lo1]
      end)
    end

    test "a snapshot without the multi-homed fields falls back to the primaries" do
      legacy = %{
        inet: @lo1,
        inet6: nil,
        inet6_all: [],
        multicast_interfaces: %{inet: [], inet6: []}
      }

      with_snapshot(legacy, fn ->
        assert Acceptor.announce_sources() == %{inet: [@lo1], inet6: []}
        assert Acceptor.all_ipv4() == [@lo1]
      end)
    end

    test "a source the host no longer owns is not announced, without raising" do
      # TEST-NET-2 is never configured on a host: the bind fails.
      refute Acceptor.source_reaches?({198, 51, 100, 77}, {198, 51, 100, 1}, 6969)
      # A loopback destination is reachable only from a loopback source.
      refute Acceptor.source_reaches?({192, 168, 1, 15}, @lo1, 6969)
      # Family mismatch.
      refute Acceptor.source_reaches?(@lo1, {0, 0, 0, 0, 0, 0, 0, 1}, 6969)
      assert Acceptor.source_reaches?(@lo1, @lo1, 6969)
    end
  end

  describe "Tracker.Fanout" do
    test "returns results in job order and turns a crash into that job's error" do
      results =
        Fanout.run(
          [{:primary, 1}, {:secondary, :boom}, {:secondary, 3}],
          fn
            :boom -> raise "source exploded"
            n -> resp([n])
          end,
          max_concurrency: 4
        )

      assert [
               %Response{peers: [1]},
               %Error{reason: {:source_crashed, "source exploded"}},
               %Response{peers: [3]}
             ] =
               results
    end

    test "never runs more than max_concurrency jobs at once" do
      parent = self()

      runner =
        Task.async(fn ->
          Fanout.run(Enum.map(1..4, &{:primary, &1}), blocking_job(parent), max_concurrency: 2)
        end)

      assert_receive {:job_started, 1, pid1}
      assert_receive {:job_started, 2, pid2}
      # The third job only starts once a slot frees up.
      assert running_jobs(runner) == 2
      refute_received {:job_started, 3, _pid}

      send(pid1, :release)
      assert_receive {:job_started, 3, pid3}
      send(pid2, :release)
      assert_receive {:job_started, 4, pid4}
      send(pid3, :release)
      send(pid4, :release)

      assert [
               %Response{peers: [1]},
               %Response{peers: [2]},
               %Response{peers: [3]},
               %Response{peers: [4]}
             ] =
               Task.await(runner)
    end

    test "after the first success a hung secondary is abandoned, a hung primary is not" do
      parent = self()

      runner =
        Task.async(fn ->
          Fanout.run(
            [{:primary, :fast}, {:primary, :slow}, {:secondary, :hung}, {:secondary, :queued}],
            fn
              :fast ->
                resp([:fast])

              name ->
                send(parent, {:job_started, name, self()})

                receive do
                  :release -> resp([name])
                end
            end,
            max_concurrency: 3,
            grace_ms: 0
          )
        end)

      assert_receive {:job_started, :slow, slow}
      # The secondary was killed at the end of the (zero) grace window and the
      # queued one never started; the slow primary still answers.
      send(slow, :release)

      assert [
               %Response{peers: [:fast]},
               %Response{peers: [:slow]},
               %Error{reason: :source_abandoned},
               %Error{reason: :source_abandoned}
             ] = Task.await(runner)

      refute_received {:job_started, :queued, _pid}
    end

    test "with no success yet, a failing source does not cut the others short" do
      parent = self()

      runner =
        Task.async(fn ->
          Fanout.run(
            [{:primary, :fails}, {:secondary, :slow}],
            fn
              :fails ->
                %Error{reason: :timeout}

              :slow ->
                send(parent, {:job_started, :slow, self()})

                receive do
                  :release -> resp([:slow])
                end
            end,
            grace_ms: 0
          )
        end)

      assert_receive {:job_started, :slow, slow}
      send(slow, :release)
      assert [%Error{reason: :timeout}, %Response{peers: [:slow]}] = Task.await(runner)
    end
  end

  describe "UDP tracker announce from several local addresses (BEP 7 + BEP 15)" do
    @describetag skip: @alias_skip

    test "each distinct source announces once, with the event, and peers are merged" do
      {port, server} =
        start_udp_tracker(
          peers: %{
            @lo1 => [{{10, 1, 0, 1}, 6881}, {{10, 1, 0, 2}, 6881}],
            @lo2 => [{{10, 1, 0, 2}, 6881}, {{10, 1, 0, 3}, 6881}],
            @lo3 => [{{10, 1, 0, 3}, 6881}, {{10, 1, 0, 4}, 6881}]
          }
        )

      on_exit(fn -> Process.exit(server, :kill) end)

      result =
        Tracker.request!(
          "udp://127.0.0.1:#{port}/announce",
          @hash,
          @started,
          # duplicates and the primary listed again must not add announces
          @fast_fail ++ [announce_sources: %{inet: [@lo1, @lo2, @lo3, @lo2, @lo1], inet6: []}]
        )

      assert %Response{peers: peers} = result

      assert sorted(peers, &{&1.ip, &1.port}) == [
               {{10, 1, 0, 1}, 6881},
               {{10, 1, 0, 2}, 6881},
               {{10, 1, 0, 3}, 6881},
               {{10, 1, 0, 4}, 6881}
             ]

      announces = collect_udp_announces(3)
      assert sorted(announces, & &1.source) == [@lo1, @lo2, @lo3]
      assert Enum.all?(announces, &(&1.event == Torrent.started()))
      refute_received {:udp_announce, _announce}

      # An added source leaves ip_field to the packet source (BEP 15).
      for %{source: source, ip_field: ip_field} <- announces, source != @lo1 do
        assert ip_field == <<0::32>>
      end
    end

    test "a single address per family announces once, as before" do
      {port, server} = start_udp_tracker(peers: %{@lo1 => [{{10, 1, 0, 1}, 6881}]})
      on_exit(fn -> Process.exit(server, :kill) end)

      assert %Response{peers: [%Peer{ip: {10, 1, 0, 1}}]} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 @started,
                 @fast_fail ++ [announce_sources: %{inet: [@lo1], inet6: []}]
               )

      assert [%{source: @lo1, event: 2}] = collect_udp_announces(1)
      refute_received {:udp_announce, _announce}
    end

    test "a tracker error on one source does not lose the others' peers" do
      {port, server} =
        start_udp_tracker(
          peers: %{@lo1 => [{{10, 1, 0, 1}, 6881}], @lo3 => [{{10, 1, 0, 3}, 6881}]},
          error_from: [@lo2]
        )

      on_exit(fn -> Process.exit(server, :kill) end)

      assert %Response{peers: peers} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 @started,
                 @fast_fail ++ [announce_sources: %{inet: [@lo1, @lo2, @lo3], inet6: []}]
               )

      assert sorted(peers, & &1.ip) == [{10, 1, 0, 1}, {10, 1, 0, 3}]
    end

    test "a black-holed source does not hold the answer back past the grace window" do
      # 127.0.0.3's datagrams are dropped: that source would wait out the
      # whole BEP 15 receive timeout (15 s) on its own.
      {port, server} =
        start_udp_tracker(peers: %{@lo1 => [{{10, 1, 0, 1}, 6881}]}, drop_from: [@lo3])

      on_exit(fn -> Process.exit(server, :kill) end)

      started_at = System.monotonic_time(:millisecond)

      assert %Response{peers: [%Peer{ip: {10, 1, 0, 1}}]} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 @started,
                 @fast_fail ++
                   [announce_sources: %{inet: [@lo1, @lo3], inet6: []}, source_grace_ms: 0]
               )

      assert System.monotonic_time(:millisecond) - started_at < 10_000
    end

    test "a malformed concurrency setting falls back to the default instead of hanging" do
      {port, server} =
        start_udp_tracker(
          peers: %{@lo1 => [{{10, 1, 0, 1}, 6881}], @lo2 => [{{10, 1, 0, 2}, 6881}]}
        )

      on_exit(fn -> Process.exit(server, :kill) end)

      with_tracker_env([max_concurrent_source_announces: 0, source_grace_ms: -1], fn ->
        assert %Response{peers: peers} =
                 Tracker.request!(
                   "udp://127.0.0.1:#{port}/announce",
                   @hash,
                   @started,
                   @fast_fail ++ [announce_sources: %{inet: [@lo1, @lo2], inet6: []}]
                 )

        assert sorted(peers, & &1.ip) == [{10, 1, 0, 1}, {10, 1, 0, 2}]
      end)
    end

    test "when every source fails, the primary's error is the answer" do
      {port, server} = start_udp_tracker(peers: %{}, error_from: [@lo1, @lo2])
      on_exit(fn -> Process.exit(server, :kill) end)

      assert %Error{reason: "tracker error for 127.0.0.1"} =
               Tracker.request!(
                 "udp://127.0.0.1:#{port}/announce",
                 @hash,
                 @started,
                 @fast_fail ++ [announce_sources: %{inet: [@lo1, @lo2], inet6: []}]
               )
    end
  end

  describe "HTTP tracker announce from several local addresses (BEP 7)" do
    @describetag skip: @alias_skip

    test "each source connects from its own address and carries the event once" do
      {port, server} = start_http_tracker(self(), 3)
      on_exit(fn -> Process.exit(server, :kill) end)

      assert %Response{peers: peers} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce?passkey=secret",
                 @hash,
                 @started,
                 @fast_fail ++ [announce_sources: %{inet: [@lo1, @lo2, @lo3, @lo3], inet6: []}]
               )

      assert sorted(peers, & &1.ip) == [@lo1, @lo2, @lo3]

      announces =
        for _ <- 1..3 do
          assert_receive {:http_announce, source, query}, 5_000
          {source, query}
        end

      assert sorted(announces, &elem(&1, 0)) == [@lo1, @lo2, @lo3]

      for {_source, query} <- announces do
        assert query["event"] == "started"
        assert query["passkey"] == "secret"
        refute Map.has_key?(query, "ip")
      end

      refute_received {:http_announce, _source, _query}
    end
  end

  ## Fanout helpers

  defp sorted(list, fun), do: Enum.sort(Enum.map(list, fun))

  defp resp(peers), do: %Response{interval: 1_800, complete: 0, incomplete: 0, peers: peers}

  defp blocking_job(parent) do
    fn n ->
      send(parent, {:job_started, n, self()})

      receive do
        :release -> resp([n])
      end
    end
  end

  # Job processes are linked to the runner (Task.async); the runner is also
  # linked to this test process.
  defp running_jobs(%Task{pid: runner}) do
    {:links, links} = Process.info(runner, :links)
    Enum.count(links, &(&1 != self()))
  end

  ## Snapshot / config helpers

  defp snapshot(v4s) do
    %{
      inet: List.first(v4s),
      inet6: nil,
      inet_all: v4s,
      inet6_all: [],
      multicast_interfaces: %{inet: [], inet6: []},
      announce_sources: %{inet: v4s, inet6: []}
    }
  end

  defp with_snapshot(snapshot, fun) do
    key = Acceptor.ip_cache_key()
    previous = :persistent_term.get(key, :missing)
    cache_pid = Process.whereis(Acceptor.IpCache)

    if cache_pid, do: :sys.suspend(cache_pid)
    :persistent_term.put(key, snapshot)

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

  defp with_tracker_env(env, fun) do
    previous = Application.get_env(:elixir_torrent, :tracker, :missing)
    Application.put_env(:elixir_torrent, :tracker, env)

    try do
      fun.()
    after
      case previous do
        :missing -> Application.delete_env(:elixir_torrent, :tracker)
        value -> Application.put_env(:elixir_torrent, :tracker, value)
      end
    end
  end

  ## Fake BEP 15 tracker on 127.0.0.1: answers per source address

  defp start_udp_tracker(opts) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_udp.open(0, [:binary, :inet, active: true, ip: @lo1])
        {:ok, port} = :inet.port(socket)
        send(parent, {:udp_tracker_ready, port, self()})
        udp_tracker_loop(socket, parent, Map.new(opts))
      end)

    receive do
      {:udp_tracker_ready, port, ^pid} -> {port, pid}
    after
      5_000 -> flunk("UDP tracker failed to start")
    end
  end

  defp udp_tracker_loop(socket, parent, state) do
    receive do
      {:udp, ^socket, ip, port, data} ->
        unless ip in Map.get(state, :drop_from, []) do
          case udp_tracker_reply(data, ip, parent, state) do
            nil -> :ok
            reply -> :gen_udp.send(socket, ip, port, reply)
          end
        end

        udp_tracker_loop(socket, parent, state)
    end
  end

  defp udp_tracker_reply(
         <<protocol_id::binary-size(8), 0::32, tid::binary-size(4)>>,
         _ip,
         _parent,
         _state
       )
       when protocol_id == @protocol_id,
       do: <<0::32, tid::binary, @connection_id::binary>>

  defp udp_tracker_reply(
         <<_cid::binary-size(8), 1::32, tid::binary-size(4), _hash::binary-size(20),
           _peer_id::binary-size(20), _downloaded::64, _left::64, _uploaded::64, event::32,
           ip_field::binary-size(4), _rest::binary>>,
         ip,
         parent,
         state
       ) do
    send(parent, {:udp_announce, %{source: ip, event: event, ip_field: ip_field}})

    if ip in Map.get(state, :error_from, []) do
      <<3::32, tid::binary, "tracker error for ", Acceptor.format_ip(ip)::binary>>
    else
      peers =
        state.peers
        |> Map.get(ip, [])
        |> Enum.map(fn {{a, b, c, d}, peer_port} -> <<a, b, c, d, peer_port::16>> end)
        |> IO.iodata_to_binary()

      <<1::32, tid::binary, 1200::32, 5::32, 10::32, peers::binary>>
    end
  end

  defp udp_tracker_reply(_data, _ip, _parent, _state), do: nil

  defp collect_udp_announces(count) do
    for _ <- 1..count do
      assert_receive {:udp_announce, announce}, 5_000
      announce
    end
  end

  ## Fake HTTP tracker on 127.0.0.1: answers with the connection's source as peer

  defp start_http_tracker(parent, connections) do
    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, :inet, active: false, reuseaddr: true, ip: @lo1])

        {:ok, port} = :inet.port(listen)
        send(parent, {:http_tracker_ready, port, self()})

        for _ <- 1..connections do
          {:ok, socket} = :gen_tcp.accept(listen, 5_000)
          serve_http_announce(socket, parent)
        end

        :gen_tcp.close(listen)
      end)

    receive do
      {:http_tracker_ready, port, ^pid} -> {port, pid}
    after
      5_000 -> flunk("HTTP tracker failed to start")
    end
  end

  defp serve_http_announce(socket, parent) do
    {:ok, {{a, b, c, d} = source, _source_port}} = :inet.peername(socket)
    {:ok, request} = recv_http_headers(socket, "")
    [request_line | _] = String.split(request, "\r\n")
    ["GET", target, _version] = String.split(request_line, " ")
    %URI{query: query} = URI.parse(target)
    query = URI.decode_query(query)
    send(parent, {:http_announce, source, query})

    body = Bento.encode!(%{"interval" => 1_200, "peers" => <<a, b, c, d, 6881::16>>})

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

    :gen_tcp.close(socket)
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
end

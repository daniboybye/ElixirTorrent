defmodule DHT.CoverageBatchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DHT.{Compact, KRPC, RoutingStore, RoutingTable, RoutingTables, Token}

  @local_id <<0::160>>
  @query_id <<1::160>>
  @info_hash <<51::160>>

  setup do
    previous = Application.get_env(:elixir_torrent, :dht, [])

    Application.put_env(:elixir_torrent, :dht,
      bootstrap_routers: [],
      query_timeout_ms: 5_000,
      lookup_timeout_ms: 30_000
    )

    on_exit(fn -> Application.put_env(:elixir_torrent, :dht, previous) end)
    :ok
  end

  describe "handle_info/2 timer and maintenance callbacks" do
    test "rotate_tokens, persist_routing, and refresh_buckets survive with loopback refresh query" do
      {server, _server_ip, _server_port} = udp_socket()
      {remote, remote_ip, remote_port} = udp_socket()
      close_on_exit([server, remote])

      stale_ms = System.monotonic_time(:millisecond) - 16 * 60 * 1_000
      contact = contact(40, remote_ip, remote_port)

      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(contact, now_ms: stale_ms)

      stale_ms = System.monotonic_time(:millisecond) - 6 * 60 * 1_000
      tokens_before = Token.new(now_ms: stale_ms)
      state = dht_state(server, tables, tokens: tokens_before)

      assert {:noreply, rotated} = DHT.handle_info(:rotate_tokens, state)
      assert rotated.tokens.current_secret != tokens_before.current_secret
      assert rotated.tokens.previous_secret == tokens_before.current_secret

      tmp = System.tmp_dir!()
      prev_cwd = File.cwd!()
      File.cd!(tmp)

      on_exit(fn -> File.cd!(prev_cwd) end)

      assert {:noreply, ^rotated} = DHT.handle_info(:persist_routing, rotated)
      assert File.regular?(RoutingStore.path())

      assert {:noreply, refreshed} = DHT.handle_info(:refresh_buckets, rotated)
      query = recv_query(remote)
      assert query.method == :find_node
      assert byte_size(query.target) == 20
      refute map_size(refreshed.pending) == 0
    end
  end

  describe "handle_info/2 UDP ingress and errors" do
    test "malformed decode and inbound KRPC error packets leave routing state intact" do
      {server, server_ip, server_port} = udp_socket()
      {client, client_ip, client_port} = udp_socket()
      close_on_exit([server, client])

      tables = RoutingTables.new(@local_id)
      node_count_before = RoutingTables.node_count(tables)
      state = dht_state(server, tables)

      assert {:noreply, after_garbage} =
               DHT.handle_info(
                 {:udp, server, client_ip, client_port, <<255, 255, 255>>},
                 state
               )

      assert RoutingTables.node_count(after_garbage.routing_tables) == node_count_before

      error_packet =
        KRPC.encode_error(%{
          transaction_id: "er",
          code: 201,
          message: "A Generic Error",
          ip: Compact.encode_peer(client_ip, client_port)
        })

      assert {:noreply, after_error} =
               DHT.handle_info(
                 {:udp, server, client_ip, client_port, error_packet},
                 after_garbage
               )

      assert RoutingTables.node_count(after_error.routing_tables) == node_count_before

      assert {:noreply, ^after_error} =
               DHT.handle_info(
                 {:udp, client, server_ip, server_port, <<1, 2, 3>>},
                 after_error
               )

      log =
        capture_log(fn ->
          assert {:noreply, after_udp_error} =
                   DHT.handle_info({:udp_error, server, :econnrefused}, after_error)

          assert after_udp_error.routing_tables == after_error.routing_tables
        end)

      assert log =~ "DHT UDP error"
    end

    test "inbound ping returns BEP 5 pong with version on the wire" do
      {server, _server_ip, _server_port} = udp_socket()
      {client, client_ip, client_port} = udp_socket()
      close_on_exit([server, client])

      query = %{method: :ping, transaction_id: "pg", node_id: @query_id, version: "ET01"}

      assert {:noreply, _state} =
               DHT.handle_info(
                 {:udp, server, client_ip, client_port, KRPC.encode_query(query)},
                 dht_state(server, RoutingTables.new(@local_id))
               )

      assert {:ok, {_ip, _port, packet}} = :gen_udp.recv(client, 0, 1_000)
      assert {:ok, {:response, response}} = KRPC.decode(packet)
      assert response.node_id == @local_id
      assert response.transaction_id == "pg"
      assert is_binary(response.version)
    end

    test "find_node and get_peers with missing arguments return 203 Protocol Error" do
      {server, _server_ip, _server_port} = udp_socket()
      {client, client_ip, client_port} = udp_socket()
      close_on_exit([server, client])

      state = dht_state(server, RoutingTables.new(@local_id))

      find_node_bad =
        Bento.encode!(%{
          "t" => "fn",
          "y" => "q",
          "q" => "find_node",
          "a" => %{"id" => @query_id}
        })

      assert {:noreply, _} =
               DHT.handle_info(
                 {:udp, server, client_ip, client_port, find_node_bad},
                 state
               )

      assert {:ok, {_ip, _port, packet1}} = :gen_udp.recv(client, 0, 1_000)
      assert {:ok, {:error, err1}} = KRPC.decode(packet1)
      assert err1.code == 203
      assert err1.message == "Protocol Error"

      get_peers_bad =
        Bento.encode!(%{
          "t" => "gp",
          "y" => "q",
          "q" => "get_peers",
          "a" => %{"id" => @query_id, "info_hash" => <<0::128>>}
        })

      assert {:noreply, _} =
               DHT.handle_info(
                 {:udp, server, client_ip, client_port, get_peers_bad},
                 state
               )

      assert {:ok, {_ip, _port, packet2}} = :gen_udp.recv(client, 0, 1_000)
      assert {:ok, {:error, err2}} = KRPC.decode(packet2)
      assert err2.code == 203
    end
  end

  describe "handle_info/2 lookup and query timeout lifecycle" do
    test "query_timeout on lookup pending schedules lookup_step" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      lookup_ref = make_ref()
      node = contact(60, {127, 0, 0, 1}, 40_060)
      tables = RoutingTables.new(@local_id) |> RoutingTables.insert(node)
      tid = "qt"

      pending = %{
        type: :lookup,
        lookup_ref: lookup_ref,
        node_id: node.id,
        node: RoutingTable.find_entry(tables.v4, node.id),
        timer_ref: Process.send_after(self(), :unused, 60_000)
      }

      lookup = %{
        ref: lookup_ref,
        purpose: :peer_lookup,
        from: {self(), make_ref()},
        hash: @info_hash,
        shortlist: [%{id: node.id, queried?: false}],
        peers: [],
        announce_nodes: %{},
        queried: MapSet.new(),
        bootstrap_waits: 0,
        timer_ref: Process.send_after(self(), :unused_lookup, 60_000)
      }

      state =
        dht_state(server, tables,
          pending: %{tid => pending},
          lookups: %{lookup_ref => lookup},
          bootstrapped?: true
        )

      assert {:noreply, _} = DHT.handle_info({:query_timeout, tid}, state)
      assert_receive {:lookup_step, ^lookup_ref}
    end

    test "lookup_timeout replies, drops, and ignores missing refs" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])
      state = dht_state(server, RoutingTables.new(@local_id), bootstrapped?: true)

      missing = make_ref()
      assert {:noreply, ^state} = DHT.handle_info({:lookup_timeout, missing}, state)

      bootstrap_ref = make_ref()

      bootstrap_lookup = %{
        ref: bootstrap_ref,
        purpose: :bootstrap,
        hash: @local_id,
        shortlist: [],
        peers: [],
        queried: MapSet.new(),
        timer_ref: Process.send_after(self(), :unused, 60_000)
      }

      boot_state = %{state | lookups: %{bootstrap_ref => bootstrap_lookup}}

      assert {:noreply, after_bootstrap} =
               DHT.handle_info({:lookup_timeout, bootstrap_ref}, boot_state)

      refute Map.has_key?(after_bootstrap.lookups, bootstrap_ref)

      peer = %Peer{ip: {198, 51, 100, 5}, port: 6885}
      reply_tag = make_ref()
      lookup_ref = make_ref()

      lookup = %{
        ref: lookup_ref,
        purpose: :peer_lookup,
        from: {self(), reply_tag},
        hash: @info_hash,
        shortlist: [],
        peers: [peer],
        announce_nodes: %{},
        queried: MapSet.new(),
        bootstrap_waits: 0,
        timer_ref: Process.send_after(self(), :unused, 60_000)
      }

      with_peers = %{after_bootstrap | lookups: %{lookup_ref => lookup}}

      assert {:noreply, after_ok} =
               DHT.handle_info({:lookup_timeout, lookup_ref}, with_peers)

      assert_receive {^reply_tag, {:ok, peers}}
      assert [%Peer{ip: {198, 51, 100, 5}, port: 6885}] = peers
      refute Map.has_key?(after_ok.lookups, lookup_ref)

      empty_tag = make_ref()
      empty_ref = make_ref()

      empty_lookup = %{
        ref: empty_ref,
        purpose: :peer_lookup,
        from: {self(), empty_tag},
        hash: @info_hash,
        shortlist: [],
        peers: [],
        announce_nodes: %{},
        queried: MapSet.new(),
        bootstrap_waits: 0,
        timer_ref: Process.send_after(self(), :unused, 60_000)
      }

      empty_state = %{after_ok | lookups: %{empty_ref => empty_lookup}}

      assert {:noreply, after_empty} =
               DHT.handle_info({:lookup_timeout, empty_ref}, empty_state)

      assert_receive {^empty_tag, {:error, :no_peers}}
      refute Map.has_key?(after_empty.lookups, empty_ref)
    end

    test "get_peers handle_call completes via loopback values response" do
      {server, _server_ip, _server_port} = udp_socket()
      {remote, remote_ip, remote_port} = udp_socket()
      close_on_exit([server, remote])

      node = contact(70, remote_ip, remote_port)

      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(node, now_ms: System.monotonic_time(:millisecond))

      state = dht_state(server, tables, bootstrapped?: true, port: 6881)
      caller_tag = make_ref()
      from = {self(), caller_tag}

      assert {:noreply, looking} =
               DHT.handle_call({:get_peers, @info_hash, 5_000}, from, state)

      [{lookup_ref, %{purpose: :peer_lookup}}] = Map.to_list(looking.lookups)
      assert_receive {:lookup_step, ^lookup_ref}

      assert {:noreply, queried} = DHT.handle_info({:lookup_step, lookup_ref}, looking)

      outbound = recv_query(remote)
      assert outbound.method == :get_peers
      assert outbound.info_hash == @info_hash

      peer_blob = Compact.encode_peer({203, 0, 113, 5}, 6889)

      response = %{
        transaction_id: outbound.transaction_id,
        node_id: node.id,
        values: [peer_blob]
      }

      assert {:noreply, merged} =
               DHT.handle_info(
                 {:udp, server, remote_ip, remote_port, KRPC.encode_response(response)},
                 queried
               )

      assert_receive {:lookup_step, ^lookup_ref}
      assert {:noreply, _} = DHT.handle_info({:lookup_step, lookup_ref}, merged)

      assert_receive {^caller_tag, {:ok, found}}
      assert [%Peer{ip: {203, 0, 113, 5}, port: 6889}] = found
    end

    test "lookup_step and dispatch_pending ignore dropped lookup refs" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      gone = make_ref()
      state = dht_state(server, RoutingTables.new(@local_id))

      assert {:noreply, ^state} = DHT.handle_info({:lookup_step, gone}, state)

      responder = contact(71, {127, 0, 0, 1}, 40_071)
      tid = "orphan"

      pending = %{
        type: :lookup,
        lookup_ref: gone,
        node_id: responder.id,
        node: responder,
        timer_ref: Process.send_after(self(), :unused, 60_000)
      }

      orphan_state = %{state | pending: %{tid => pending}}

      response = %{transaction_id: tid, node_id: responder.id, nodes: <<>>}

      assert {:noreply, same} =
               DHT.handle_info(
                 {:udp, server, responder.ip, responder.port, KRPC.encode_response(response)},
                 orphan_state
               )

      assert same.pending == %{}
    end
  end

  describe "handle_info/2 bootstrap and announce branches" do
    test ":bootstrap is idempotent once bootstrapped? is set" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      node = contact(80, {127, 0, 0, 1}, 40_080)
      tables = RoutingTables.new(@local_id) |> RoutingTables.insert(node)

      state = dht_state(server, tables, bootstrapped?: true, lookups: %{})

      assert {:noreply, ^state} = DHT.handle_info(:bootstrap, state)
    end

    test "reannounce clears timer and starts announce lookup" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      hash = <<82::160>>
      timer = Process.send_after(self(), {:reannounce, hash, 6881}, 60_000)

      state =
        dht_state(server, RoutingTables.new(@local_id),
          announce_timers: %{hash => timer},
          bootstrapped?: true
        )

      assert {:noreply, restarted} =
               DHT.handle_info({:reannounce, hash, 6881}, state)

      refute Map.has_key?(restarted.announce_timers, hash)

      assert Enum.any?(restarted.lookups, fn {_ref, l} ->
               l.purpose == :announce and l.hash == hash
             end)
    end

    test "finish_announce records announce_nodes token then schedules reannounce timer" do
      {server, _server_ip, _server_port} = udp_socket()
      {remote, remote_ip, remote_port} = udp_socket()
      close_on_exit([server, remote])

      ref = make_ref()
      hash = <<83::160>>

      lookup = %{
        ref: ref,
        purpose: :announce,
        hash: hash,
        bt_port: 6881,
        announce_nodes: %{{remote_ip, remote_port} => "tok12345"},
        shortlist: [],
        peers: [],
        queried: MapSet.new(),
        timer_ref: Process.send_after(self(), :unused, 60_000)
      }

      state =
        dht_state(server, RoutingTables.new(@local_id),
          lookups: %{ref => lookup},
          bootstrapped?: true,
          port: 6881
        )

      assert {:noreply, finished} = DHT.handle_info({:lookup_timeout, ref}, state)

      query = recv_query(remote)
      assert query.method == :announce_peer
      assert query.token == "tok12345"
      assert query.implied_port == 1

      assert Map.has_key?(finished.announce_timers, hash)
      refute Map.has_key?(finished.lookups, ref)
    end
  end

  describe "handle_cast/2 and catch-all handle_info/2" do
    test "announce cast is ignored while reannounce timer is active" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      hash = <<84::160>>
      timer = Process.send_after(self(), :noop, 60_000)

      state =
        dht_state(server, RoutingTables.new(@local_id),
          announce_timers: %{hash => timer},
          bootstrapped?: true
        )

      assert {:noreply, same} = DHT.handle_cast({:announce, hash, 6881}, state)
      assert same.lookups == %{}
    end

    test "seed_node cast sends loopback ping query" do
      {server, _server_ip, _server_port} = udp_socket()
      {remote, remote_ip, remote_port} = udp_socket()
      close_on_exit([server, remote])

      assert {:noreply, _} =
               DHT.handle_cast(
                 {:seed_node, remote_ip, remote_port},
                 dht_state(server, RoutingTables.new(@local_id))
               )

      query = recv_query(remote)
      assert query.method == :ping
      assert query.node_id == @local_id
    end

    test "EXIT :normal is ignored and abnormal stops; catch-all is noreply" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])
      state = dht_state(server, RoutingTables.new(@local_id))

      assert {:noreply, ^state} = DHT.handle_info({:EXIT, self(), :normal}, state)
      assert {:stop, :kill, ^state} = DHT.handle_info({:EXIT, self(), :kill}, state)
      assert {:noreply, ^state} = DHT.handle_info(:coverage_probe_message, state)
    end
  end

  describe "handle_info/2 query failure node_id branch" do
    test "query_timeout marks failure when pending carries node_id only" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      node = contact(90, {127, 0, 0, 1}, 40_090)
      tables = RoutingTables.new(@local_id) |> RoutingTables.insert(node)
      tid = "nid"

      pending = %{
        type: :lookup,
        lookup_ref: make_ref(),
        node_id: node.id,
        timer_ref: Process.send_after(self(), :unused, 60_000)
      }

      state = dht_state(server, tables, pending: %{tid => pending})

      assert {:noreply, after_fail} = DHT.handle_info({:query_timeout, tid}, state)

      assert %{status: :good, failed_queries: 1} =
               RoutingTable.find_entry(after_fail.routing_tables.v4, node.id)
    end
  end

  describe "lookup bootstrap wait and pending cap" do
    test "empty routing table peer lookup enters bootstrap wait without external DNS" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      state = dht_state(server, RoutingTables.new(@local_id), bootstrapped?: false)
      caller_tag = make_ref()

      assert {:noreply, looking} =
               DHT.handle_call({:get_peers, @info_hash, 5_000}, {self(), caller_tag}, state)

      [{lookup_ref, lookup}] = Map.to_list(looking.lookups)
      assert lookup.bootstrap_waits == 0

      assert {:noreply, waiting} = DHT.handle_info({:lookup_step, lookup_ref}, looking)
      updated = Map.fetch!(waiting.lookups, lookup_ref)
      assert updated.bootstrap_waits == 1
      assert waiting.bootstrapped?
    end

    test "add_node cast still learns contact but skips ping when pending map is full" do
      {server, _ip, _port} = udp_socket()
      close_on_exit([server])

      node = contact(95, {127, 0, 0, 1}, 40_095)

      pending =
        for i <- 1..256, into: %{} do
          tid = <<i::16>>

          {tid,
           %{
             type: :query,
             node: contact(i, {127, 0, 0, 1}, 30_000 + i),
             timer_ref: Process.send_after(self(), :noop, 60_000)
           }}
        end

      state = dht_state(server, RoutingTables.new(@local_id), pending: pending)

      assert {:noreply, after_add} = DHT.handle_cast({:add_node, node}, state)
      assert map_size(after_add.pending) == 256
      assert RoutingTable.find_entry(after_add.routing_tables.v4, node.id)
    end
  end

  defp dht_state(socket, tables, opts \\ []) do
    %DHT{
      socket_v4: socket,
      socket_v6: Keyword.get(opts, :socket_v6),
      node_id: @local_id,
      port: Keyword.get(opts, :port),
      routing_tables: tables,
      tokens: Keyword.get(opts, :tokens, Token.new()),
      peer_store: Keyword.get(opts, :peer_store, %{}),
      pending: Keyword.get(opts, :pending, %{}),
      lookups: Keyword.get(opts, :lookups, %{}),
      announce_tokens: Keyword.get(opts, :announce_tokens, %{}),
      announce_timers: Keyword.get(opts, :announce_timers, %{}),
      bootstrapped?: Keyword.get(opts, :bootstrapped?, false)
    }
  end

  defp contact(id, ip, port), do: %{id: <<id::160>>, ip: ip, port: port}

  defp udp_socket do
    {:ok, socket} =
      :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])

    {:ok, {ip, port}} = :inet.sockname(socket)
    {socket, ip, port}
  end

  defp recv_query(socket) do
    assert {:ok, {_ip, _port, packet}} = :gen_udp.recv(socket, 0, 1_000)
    assert {:ok, {:query, query}} = KRPC.decode(packet)
    query
  end

  defp close_on_exit(sockets) do
    on_exit(fn -> Enum.each(sockets, &:gen_udp.close/1) end)
  end
end

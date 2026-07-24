defmodule DHT.RoutingMaintenanceTest do
  use ExUnit.Case, async: false

  alias DHT.{KRPC, RoutingTable, RoutingTables, Token}

  @local_id <<0::160>>

  setup do
    previous = Application.get_env(:elixir_torrent, :dht, [])
    Application.put_env(:elixir_torrent, :dht, bootstrap_routers: [], query_timeout_ms: 5_000)

    on_exit(fn -> Application.put_env(:elixir_torrent, :dht, previous) end)
    :ok
  end

  test "a full bucket pings a questionable incumbent twice before replacing it" do
    {server, _server_ip, _server_port} = udp_socket()
    {incumbent_socket, incumbent_ip, incumbent_port} = udp_socket()
    {candidate_socket, candidate_ip, candidate_port} = udp_socket()
    close_on_exit([server, incumbent_socket, candidate_socket])

    now = System.monotonic_time(:millisecond)
    incumbent = contact(1, incumbent_ip, incumbent_port)

    tables =
      Enum.reduce(1..8, RoutingTables.new(@local_id), fn id, tables ->
        node =
          if id == 1,
            do: incumbent,
            else: contact(id, {127, 0, 0, 1}, 30_000 + id)

        RoutingTables.insert(tables, node, now_ms: now)
      end)

    tables = %{
      tables
      | v4: RoutingTable.mark_questionable(tables.v4, incumbent.id, now_ms: now)
    }

    state = dht_state(server, tables)
    candidate = contact(9, candidate_ip, candidate_port)

    query = %{
      method: :ping,
      transaction_id: "new",
      node_id: candidate.id
    }

    assert {:noreply, result} =
             DHT.handle_info(
               {:udp, server, candidate_ip, candidate_port, KRPC.encode_query(query)},
               state
             )

    assert {:ok, {_ip, _port, ping_packet}} = :gen_udp.recv(incumbent_socket, 0, 1_000)
    assert {:ok, {:query, %{method: :ping}}} = KRPC.decode(ping_packet)

    assert RoutingTable.find_entry(result.routing_tables.v4, incumbent.id)
    refute RoutingTable.find_entry(result.routing_tables.v4, candidate.id)

    assert Enum.any?(result.pending, fn
             {_tid, %{type: :replacement_ping, node: %{id: id}}} -> id == incumbent.id
             _ -> false
           end)

    [{first_tid, %{attempts: 1}}] = Map.to_list(result.pending)
    assert {:noreply, retried} = DHT.handle_info({:query_timeout, first_tid}, result)
    assert {:ok, {_ip, _port, retry_packet}} = :gen_udp.recv(incumbent_socket, 0, 1_000)
    assert {:ok, {:query, %{method: :ping}}} = KRPC.decode(retry_packet)

    assert %{status: :questionable, failed_queries: 1} =
             RoutingTable.find_entry(retried.routing_tables.v4, incumbent.id)

    refute RoutingTable.find_entry(retried.routing_tables.v4, candidate.id)

    [{second_tid, %{attempts: 2}}] = Map.to_list(retried.pending)
    assert {:noreply, replaced} = DHT.handle_info({:query_timeout, second_tid}, retried)

    refute RoutingTable.find_entry(replaced.routing_tables.v4, incumbent.id)
    assert RoutingTable.find_entry(replaced.routing_tables.v4, candidate.id)
  end

  test "a node becomes bad only after two consecutive missed queries" do
    {server, _ip, _port} = udp_socket()
    close_on_exit([server])
    node = contact(20, {127, 0, 0, 1}, 40_020)
    tables = RoutingTables.new(@local_id) |> RoutingTables.insert(node)
    state = dht_state(server, tables)

    first_tid = "f1"
    first = %{type: :query, node: node, method: :ping}

    assert {:noreply, after_first} =
             DHT.handle_info({:query_timeout, first_tid}, %{
               state
               | pending: %{first_tid => first}
             })

    assert %{status: :good, failed_queries: 1} =
             RoutingTable.find_entry(after_first.routing_tables.v4, node.id)

    second_tid = "f2"
    second = %{type: :query, node: node, method: :ping}

    assert {:noreply, after_second} =
             DHT.handle_info(
               {:query_timeout, second_tid},
               %{after_first | pending: %{second_tid => second}}
             )

    assert %{status: :bad, failed_queries: 2} =
             RoutingTable.find_entry(after_second.routing_tables.v4, node.id)
  end

  test "bootstrap iteratively queries closer nodes toward our own id" do
    {server, _server_ip, _server_port} = udp_socket()
    {first_socket, first_ip, first_port} = udp_socket()
    {closer_socket, closer_ip, closer_port} = udp_socket()
    close_on_exit([server, first_socket, closer_socket])

    first = contact(100, first_ip, first_port)
    closer = contact(10, closer_ip, closer_port)
    tables = RoutingTables.new(@local_id) |> RoutingTables.insert(first)
    state = dht_state(server, tables)

    assert {:noreply, bootstrapping} = DHT.handle_info(:bootstrap, state)
    assert [{ref, %{purpose: :bootstrap}}] = Map.to_list(bootstrapping.lookups)
    assert_receive {:lookup_step, ^ref}

    assert {:noreply, first_round} =
             DHT.handle_info({:lookup_step, ref}, bootstrapping)

    first_query = recv_query(first_socket)
    assert first_query.method == :find_node
    assert first_query.target == @local_id

    response = %{
      transaction_id: first_query.transaction_id,
      node_id: first.id,
      nodes: DHT.Compact.encode_nodes([closer])
    }

    assert {:noreply, discovered} =
             DHT.handle_info(
               {:udp, server, first_ip, first_port, KRPC.encode_response(response)},
               first_round
             )

    assert_receive {:lookup_step, ^ref}
    assert {:noreply, second_round} = DHT.handle_info({:lookup_step, ref}, discovered)

    closer_query = recv_query(closer_socket)
    assert closer_query.method == :find_node
    assert closer_query.target == @local_id
    assert Map.has_key?(second_round.lookups, ref)
  end

  test "an unknown KRPC query receives error 204" do
    {server, _server_ip, _server_port} = udp_socket()
    {client, client_ip, client_port} = udp_socket()
    close_on_exit([server, client])
    state = dht_state(server, RoutingTables.new(@local_id))

    query = %{
      method: {:unknown, "scrape"},
      transaction_id: "uk",
      node_id: <<77::160>>
    }

    assert {:noreply, %DHT{}} =
             DHT.handle_info(
               {:udp, server, client_ip, client_port, KRPC.encode_query(query)},
               state
             )

    assert {:ok, {_ip, _port, packet}} = :gen_udp.recv(client, 0, 1_000)
    assert {:ok, {:error, %{code: 204, message: "Method Unknown"}}} = KRPC.decode(packet)
  end

  test "outgoing announce_peer requests set implied_port to one" do
    {server, _server_ip, _server_port} = udp_socket()
    {remote, remote_ip, remote_port} = udp_socket()
    close_on_exit([server, remote])

    ref = make_ref()
    hash = <<88::160>>
    timer_ref = Process.send_after(self(), :unused_lookup_timeout, 60_000)

    lookup = %{
      ref: ref,
      purpose: :announce,
      hash: hash,
      bt_port: 6_881,
      announce_nodes: %{{remote_ip, remote_port} => "token"},
      timer_ref: timer_ref
    }

    state = %{dht_state(server, RoutingTables.new(@local_id)) | lookups: %{ref => lookup}}

    assert {:noreply, %DHT{}} = DHT.handle_info({:lookup_timeout, ref}, state)

    query = recv_query(remote)
    assert query.method == :announce_peer
    assert query.info_hash == hash
    assert query.port == 6_881
    assert query.implied_port == 1
  end

  defp dht_state(socket, tables) do
    %DHT{
      socket_v4: socket,
      socket_v6: nil,
      node_id: @local_id,
      port: 6_881,
      routing_tables: tables,
      tokens: Token.new()
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

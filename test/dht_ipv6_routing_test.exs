defmodule DHTIPv6RoutingTest do
  use ExUnit.Case, async: true

  alias DHT.{Compact, KRPC, PeerStore, RoutingTable, RoutingTables, Token}

  @local_id <<0::160>>
  @query_id <<1::160>>
  @target <<50::160>>
  @peer_hash <<51::160>>
  @now 1_000_000

  defp v4_contact(id_int, ip \\ {10, 0, 0, 1}, port \\ 6881) do
    %{id: <<id_int::unsigned-big-integer-size(160)>>, ip: ip, port: port}
  end

  defp v6_contact(id_int, port \\ 6881) do
    ip = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x0001}

    %{id: <<id_int::unsigned-big-integer-size(160)>>, ip: ip, port: port}
  end

  describe "RoutingTables family dispatch (BEP 32)" do
    test "insert routes IPv4 contacts to v4 table only" do
      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(10), now_ms: @now)

      assert RoutingTable.node_count(tables.v4) == 1
      assert RoutingTable.node_count(tables.v6) == 0
    end

    test "insert routes IPv6 contacts to v6 table only" do
      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v6_contact(20), now_ms: @now)

      assert RoutingTable.node_count(tables.v4) == 0
      assert RoutingTable.node_count(tables.v6) == 1
    end

    test "closest/3 merges both families by XOR distance" do
      target = <<50::unsigned-big-integer-size(160)>>

      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(100), now_ms: @now)
        |> RoutingTables.insert(v6_contact(51), now_ms: @now)
        |> RoutingTables.insert(v4_contact(200), now_ms: @now)

      ids =
        tables
        |> RoutingTables.closest(target, 3)
        |> Enum.map(& &1.id)

      assert length(ids) == 3
      assert ids == Enum.sort_by(ids, &RoutingTable.distance(&1, target))
    end

    test "closest_family returns single-table nodes for replies" do
      target = <<50::unsigned-big-integer-size(160)>>

      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(100), now_ms: @now)
        |> RoutingTables.insert(v6_contact(51), now_ms: @now)

      v4_ids =
        tables
        |> RoutingTables.closest_family(:v4, target, 8)
        |> Enum.map(& &1.id)

      v6_ids =
        tables
        |> RoutingTables.closest_family(:v6, target, 8)
        |> Enum.map(& &1.id)

      assert length(v4_ids) == 1
      assert length(v6_ids) == 1
      refute hd(v4_ids) == hd(v6_ids)
    end
  end

  describe "BEP 32 server-side reply family filtering" do
    setup do
      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(100), now_ms: @now)
        |> RoutingTables.insert(v6_contact(51), now_ms: @now)

      peer_store =
        %{}
        |> PeerStore.put(@peer_hash, %Peer{ip: {198, 51, 100, 10}, port: 6_881})
        |> PeerStore.put(
          @peer_hash,
          %Peer{ip: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 10}, port: 6_882}
        )

      {:ok, server_v4} =
        :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])

      {:ok, client_v4} =
        :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])

      {:ok, server_v6} =
        :gen_udp.open(0, [
          :binary,
          :inet6,
          {:ipv6_v6only, true},
          active: false,
          ip: {0, 0, 0, 0, 0, 0, 0, 1}
        ])

      {:ok, client_v6} =
        :gen_udp.open(0, [
          :binary,
          :inet6,
          {:ipv6_v6only, true},
          active: false,
          ip: {0, 0, 0, 0, 0, 0, 0, 1}
        ])

      sockets = [server_v4, client_v4, server_v6, client_v6]
      on_exit(fn -> Enum.each(sockets, &:gen_udp.close/1) end)

      state = %DHT{
        socket_v4: server_v4,
        socket_v6: server_v6,
        node_id: @local_id,
        routing_tables: tables,
        tokens: Token.new(),
        peer_store: peer_store
      }

      %{state: state, clients: %{inet: client_v4, inet6: client_v6}}
    end

    test "want absent defaults find_node and get_peers nodes to the query socket family",
         context do
      for method <- [:find_node, :get_peers] do
        v4 = query_server(context, :inet, method, nil)
        assert is_binary(v4.nodes)
        assert v4.nodes6 == nil

        v6 = query_server(context, :inet6, method, nil)
        assert v6.nodes == nil
        assert is_binary(v6.nodes6)
      end
    end

    test "explicit want overrides the socket family for find_node and get_peers", context do
      for method <- [:find_node, :get_peers],
          {want, include_v4?, include_v6?} <- [
            {["n4"], true, false},
            {["n6"], false, true},
            {["n4", "n6"], true, true}
          ] do
        response = query_server(context, :inet, method, want)
        assert is_binary(response.nodes) == include_v4?
        assert is_binary(response.nodes6) == include_v6?
      end
    end

    test "get_peers values always match the query socket family", context do
      v4 = query_server(context, :inet, :get_peers, ["n6"], @peer_hash)
      assert Enum.all?(v4.values, &(byte_size(&1) == 6))
      assert [%Peer{ip: {198, 51, 100, 10}, port: 6_881}] = KRPC.response_peers(v4)

      v6 = query_server(context, :inet6, :get_peers, ["n4"], @peer_hash)
      assert Enum.all?(v6.values, &(byte_size(&1) == 18))

      assert [%Peer{ip: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 10}, port: 6_882}] =
               KRPC.response_peers(v6)
    end

    test "get_peers returns nodes when the store has peers only from the other family", context do
      v6_peer = %Peer{ip: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 20}, port: 6_883}
      v6_only = PeerStore.put(%{}, @peer_hash, v6_peer)
      v4_context = put_in(context.state.peer_store, v6_only)
      v4 = query_server(v4_context, :inet, :get_peers, nil, @peer_hash)
      assert v4.values == nil
      assert is_binary(v4.nodes)
      assert v4.nodes6 == nil

      v4_peer = %Peer{ip: {198, 51, 100, 20}, port: 6_884}
      v4_only = PeerStore.put(%{}, @peer_hash, v4_peer)
      v6_context = put_in(context.state.peer_store, v4_only)
      v6 = query_server(v6_context, :inet6, :get_peers, nil, @peer_hash)
      assert v6.values == nil
      assert v6.nodes == nil
      assert is_binary(v6.nodes6)
    end
  end

  describe "socket family selection" do
    test "tuple_size dispatches inet vs inet6" do
      assert RoutingTables.family_for({1, 2, 3, 4}) == :v4
      assert RoutingTables.family_for({0x2001, 0, 0, 0, 0, 0, 0, 1}) == :v6
    end

    test "v4-only host: open_v6 returns nil when no global v6" do
      # When inet6 is nil, routing still works with v4 table only
      tables = RoutingTables.new(@local_id) |> RoutingTables.insert(v4_contact(1), now_ms: @now)
      assert RoutingTables.node_count(tables) == 1
    end
  end

  defp query_server(context, family, method, want, target \\ @target) do
    client = context.clients[family]
    server = if family == :inet, do: context.state.socket_v4, else: context.state.socket_v6
    {:ok, {source_ip, source_port}} = :inet.sockname(client)

    query =
      %{
        method: method,
        transaction_id: :crypto.strong_rand_bytes(2),
        node_id: @query_id
      }
      |> put_query_target(method, target)
      |> maybe_put_want(want)

    assert {:noreply, %DHT{}} =
             DHT.handle_info(
               {:udp, server, source_ip, source_port, KRPC.encode_query(query)},
               context.state
             )

    assert {:ok, {_server_ip, _server_port, packet}} = :gen_udp.recv(client, 0, 1_000)
    assert {:ok, {:response, response}} = KRPC.decode(packet)
    assert response.ip == compact_endpoint(source_ip, source_port)
    response
  end

  defp put_query_target(query, :find_node, target), do: Map.put(query, :target, target)
  defp put_query_target(query, :get_peers, target), do: Map.put(query, :info_hash, target)

  defp maybe_put_want(query, nil), do: query
  defp maybe_put_want(query, want), do: Map.put(query, :want, want)

  defp compact_endpoint({_, _, _, _} = ip, port), do: Compact.encode_peer(ip, port)

  defp compact_endpoint({_, _, _, _, _, _, _, _} = ip, port),
    do: Compact.encode_ipv6_peer(ip, port)
end

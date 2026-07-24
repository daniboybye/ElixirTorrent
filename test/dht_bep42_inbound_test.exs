defmodule DHT.BEP42InboundTest do
  use ExUnit.Case, async: true

  alias DHT.{BEP42, Compact, KRPC, RoutingTable, RoutingTables, Token}

  @local_id :binary.copy(<<0xAA>>, 20)
  @public_v4 {192, 0, 2, 1}
  @public_v6 {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}

  setup do
    {:ok, socket} = :gen_udp.open(0, [:binary, :inet, active: false])
    on_exit(fn -> :gen_udp.close(socket) end)

    state = %DHT{
      socket_v4: socket,
      socket_v6: nil,
      node_id: @local_id,
      routing_tables: RoutingTables.new(@local_id),
      tokens: Token.new()
    }

    %{state: state, socket: socket}
  end

  test "request-source and unsolicited invalid public contacts never become good", context do
    invalid_id = invalid_id(@public_v4)
    query = %{method: :ping, transaction_id: "rq", node_id: invalid_id}

    assert {:noreply, queried_state} =
             DHT.handle_info(
               {:udp, context.socket, @public_v4, 6_881, KRPC.encode_query(query)},
               context.state
             )

    refute good_entry?(queried_state.routing_tables, invalid_id)

    contact = %{id: invalid_id, ip: @public_v4, port: 6_881}
    assert {:noreply, added_state} = DHT.handle_cast({:add_node, contact}, context.state)
    refute good_entry?(added_state.routing_tables, invalid_id)
  end

  test "an invalid response source is not promoted and invalidates the queried entry", context do
    valid_id = BEP42.generate(@public_v4, 17)
    invalid_id = invalid_id(@public_v4)
    contact = %{id: valid_id, ip: @public_v4, port: 6_881}
    tables = RoutingTables.insert(context.state.routing_tables, contact)
    {tid, pending} = pending_for(contact)
    lookup_ref = make_ref()
    pending = Map.merge(pending, %{type: :lookup, lookup_ref: lookup_ref, node_id: valid_id})
    discovered_ip = {198, 51, 100, 20}
    discovered_id = BEP42.generate(discovered_ip, 21)

    state = %{context.state | routing_tables: tables, pending: %{tid => pending}}

    response = %{
      transaction_id: tid,
      node_id: invalid_id,
      token: "untrusted",
      nodes: Compact.encode_nodes([%{id: discovered_id, ip: discovered_ip, port: 6_882}])
    }

    assert {:noreply, result} =
             DHT.handle_info(
               {:udp, context.socket, @public_v4, 6_881, KRPC.encode_response(response)},
               state
             )

    refute good_entry?(result.routing_tables, invalid_id)
    assert entry_status(result.routing_tables, valid_id) == :bad
    assert good_entry?(result.routing_tables, discovered_id)
    assert result.announce_tokens == %{}
    assert_receive {:lookup_step, ^lookup_ref}
  end

  test "a response from the wrong endpoint cannot consume a pending transaction", context do
    responder_id = BEP42.generate(@public_v4, 18)
    responder = %{id: responder_id, ip: @public_v4, port: 6_881}
    {tid, pending} = pending_for(responder)
    state = %{context.state | pending: %{tid => pending}}
    response = %{transaction_id: tid, node_id: responder_id}

    assert {:noreply, result} =
             DHT.handle_info(
               {:udp, context.socket, @public_v4, 6_882, KRPC.encode_response(response)},
               state
             )

    assert Map.has_key?(result.pending, tid)
    refute good_entry?(result.routing_tables, responder_id)
  end

  test "invalid response-derived compact nodes are not inserted", context do
    responder_id = BEP42.generate(@public_v4, 19)
    invalid_id = invalid_id({9, 9, 9, 9})
    responder = %{id: responder_id, ip: @public_v4, port: 6_881}
    {tid, pending} = pending_for(responder)

    response = %{
      transaction_id: tid,
      node_id: responder_id,
      nodes: Compact.encode_nodes([%{id: invalid_id, ip: {9, 9, 9, 9}, port: 6_882}])
    }

    state = %{context.state | pending: %{tid => pending}}

    assert {:noreply, result} =
             DHT.handle_info(
               {:udp, context.socket, @public_v4, 6_881, KRPC.encode_response(response)},
               state
             )

    assert good_entry?(result.routing_tables, responder_id)
    refute good_entry?(result.routing_tables, invalid_id)
  end

  test "local and private source addresses are exempt", context do
    arbitrary_id = :binary.copy(<<0x11>>, 20)
    query = %{method: :ping, transaction_id: "lo", node_id: arbitrary_id}

    assert {:noreply, result} =
             DHT.handle_info(
               {:udp, context.socket, {10, 0, 0, 7}, 6_881, KRPC.encode_query(query)},
               context.state
             )

    assert good_entry?(result.routing_tables, arbitrary_id)
  end

  test "dual-stack compact contacts are checked against their own address family", context do
    v4_id = BEP42.generate(@public_v4, 23)
    v6_id = BEP42.generate(@public_v6, 29)
    refute BEP42.valid?(v4_id, @public_v6)
    refute BEP42.valid?(v6_id, @public_v4)

    responder_id = BEP42.generate(@public_v4, 31)
    responder = %{id: responder_id, ip: @public_v4, port: 6_881}
    {tid, pending} = pending_for(responder)

    response = %{
      transaction_id: tid,
      node_id: responder_id,
      nodes: Compact.encode_nodes([%{id: v4_id, ip: @public_v4, port: 6_882}]),
      nodes6: Compact.encode_nodes6([%{id: v6_id, ip: @public_v6, port: 6_883}])
    }

    state = %{context.state | pending: %{tid => pending}}

    assert {:noreply, result} =
             DHT.handle_info(
               {:udp, context.socket, @public_v4, 6_881, KRPC.encode_response(response)},
               state
             )

    assert good_entry?(result.routing_tables, v4_id)
    assert good_entry?(result.routing_tables, v6_id)
  end

  defp pending_for(contact) do
    tid = :crypto.strong_rand_bytes(2)
    timer_ref = Process.send_after(self(), :unused_timeout, 60_000)
    {tid, %{type: :query, node: contact, method: :find_node, timer_ref: timer_ref}}
  end

  defp invalid_id(ip) do
    <<first, rest::binary>> = BEP42.generate(ip, 7)
    <<Bitwise.bxor(first, 0xFF), rest::binary>>
  end

  defp good_entry?(tables, id), do: entry_status(tables, id) == :good

  defp entry_status(tables, id) do
    (RoutingTable.entries(tables.v4) ++ RoutingTable.entries(tables.v6))
    |> Enum.find_value(fn
      %{id: ^id, status: status} -> status
      _ -> nil
    end)
  end
end

defmodule DHT.CandidatesTest do
  @moduledoc """
  BEP 5 § Routing Table: a node seen only as the source of an inbound query is
  not good until it has answered one of our queries. It waits in
  `DHT.Candidates`, we ping the address the query came from, and only a valid
  response inserts it.
  """
  use ExUnit.Case, async: true

  alias DHT.{BEP42, Candidates, KRPC, RoutingTable, RoutingTables, Token}

  @local_id <<0::160>>
  @public_v4 {192, 0, 2, 44}
  @public_v6 {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 44}

  describe "DHT.Candidates limits" do
    test "admits, refuses a second probe of the same address, and resolves" do
      contact = %{id: <<1::160>>, ip: @public_v4, port: 6_881}

      assert {:ok, c} = Candidates.admit(Candidates.new(), contact, 0)
      assert Candidates.member?(c, {@public_v4, 6_881})
      assert {:drop, :pending, c} = Candidates.admit(c, contact, 1)

      c = Candidates.resolve(c, {@public_v4, 6_881}, :verified)
      assert Candidates.size(c) == 0

      assert %{admitted: 1, verified: 1, dropped_pending: 1, candidates: 0} =
               Candidates.stats(c)

      # Resolving an unknown key is a no-op, not a crash or a double count.
      assert Candidates.stats(Candidates.resolve(c, {@public_v4, 6_881}, :verified)).verified ==
               1
    end

    test "caps the list size and the candidates per source IP" do
      opts = [max: 3, max_per_ip: 2, max_probes: 100]

      {:ok, c} = Candidates.admit(Candidates.new(), contact(1, {198, 51, 100, 1}, 1), 0, opts)
      {:ok, c} = Candidates.admit(c, contact(2, {198, 51, 100, 1}, 2), 0, opts)
      assert {:drop, :per_ip, c} = Candidates.admit(c, contact(3, {198, 51, 100, 1}, 3), 0, opts)

      {:ok, c} = Candidates.admit(c, contact(4, {198, 51, 100, 2}, 1), 0, opts)
      assert {:drop, :full, c} = Candidates.admit(c, contact(5, {198, 51, 100, 3}, 1), 0, opts)

      assert Candidates.size(c) == 3
      assert %{dropped_per_ip: 1, dropped_full: 1} = Candidates.stats(c)
    end

    test "rate-limits new probes per window, and the window rolls over" do
      opts = [max_probes: 2, window_ms: 1_000]

      {:ok, c} = Candidates.admit(Candidates.new(), contact(1, {198, 51, 100, 1}, 1), 0, opts)
      {:ok, c} = Candidates.admit(c, contact(2, {198, 51, 100, 2}, 1), 500, opts)
      assert {:drop, :rate, c} = Candidates.admit(c, contact(3, {198, 51, 100, 3}, 1), 999, opts)
      assert {:ok, c} = Candidates.admit(c, contact(3, {198, 51, 100, 3}, 1), 1_000, opts)
      assert %{dropped_rate: 1, admitted: 3} = Candidates.stats(c)
    end

    test "a candidate expires after its TTL and the address may be probed again" do
      opts = [ttl_ms: 30_000]
      contact = contact(1, @public_v4, 6_881)

      {:ok, c} = Candidates.admit(Candidates.new(), contact, 0, opts)
      assert Candidates.size(Candidates.expire(c, 29_999, opts)) == 1

      expired = Candidates.expire(c, 30_000, opts)
      assert Candidates.size(expired) == 0
      assert Candidates.stats(expired).expired == 1

      # Expiry also runs on admit, so a stale entry never blocks its address.
      assert {:ok, again} = Candidates.admit(c, contact, 30_000, opts)
      assert Candidates.member?(again, {@public_v4, 6_881})
      assert Candidates.stats(again).expired == 1
    end
  end

  describe "inbound query sources (IPv4)" do
    setup :dht_server

    test "we answer first, then ping; an unanswered candidate never enters the table", ctx do
      {client, client_ip, client_port} = udp_socket()
      on_exit(fn -> :gen_udp.close(client) end)
      id = :binary.copy(<<0x42>>, 20)

      result = inbound_ping(ctx.state, client_ip, client_port, id, "q1")

      # The answer is the first datagram on the wire; the verification ping
      # only follows it.
      assert {:ok, {_ip, _port, first}} = :gen_udp.recv(client, 0, 1_000)
      assert {:ok, {:response, %{transaction_id: "q1"}}} = KRPC.decode(first)
      assert {:ok, {_ip, _port, second}} = :gen_udp.recv(client, 0, 1_000)
      assert {:ok, {:query, %{method: :ping, transaction_id: tid}}} = KRPC.decode(second)

      refute entry(result, id)
      assert %{type: :candidate_ping} = result.pending[tid]
      assert {:reply, %{candidates: 1, routing_v4: 0}, _} = stats(result)

      assert {:noreply, timed_out} = DHT.handle_info({:query_timeout, tid}, result)
      refute entry(timed_out, id)
      assert timed_out.pending == %{}
      assert {:reply, %{candidates: 0, unanswered: 1, verified: 0}, _} = stats(timed_out)
    end

    test "a candidate that answers our ping is inserted as good", ctx do
      id = BEP42.generate(@public_v4, 3)
      result = inbound_ping(ctx.state, @public_v4, 6_881, id, "q1")
      refute entry(result, id)

      [{tid, %{type: :candidate_ping}}] = Map.to_list(result.pending)
      verified = respond(result, @public_v4, 6_881, tid, id)

      assert %{status: :good, ip: @public_v4, port: 6_881} = entry(verified, id)
      assert {:reply, %{candidates: 0, verified: 1, routing_v4: 1}, _} = stats(verified)
    end

    test "an answer from another port does not verify the candidate", ctx do
      id = BEP42.generate(@public_v4, 4)
      result = inbound_ping(ctx.state, @public_v4, 6_881, id, "q1")
      [{tid, _pending}] = Map.to_list(result.pending)

      spoofed = respond(result, @public_v4, 6_999, tid, id)
      refute entry(spoofed, id)
      assert Map.has_key?(spoofed.pending, tid)
    end

    test "a BEP 42-invalid public source is not even probed", ctx do
      <<first, rest::binary>> = BEP42.generate(@public_v4, 5)
      invalid = <<Bitwise.bxor(first, 0xFF), rest::binary>>

      result = inbound_ping(ctx.state, @public_v4, 6_881, invalid, "q1")
      assert result.pending == %{}
      assert Candidates.size(result.candidates) == 0
    end

    test "a node already held at this address refreshes without a probe", ctx do
      id = BEP42.generate(@public_v4, 6)
      contact = %{id: id, ip: @public_v4, port: 6_881}
      tables = RoutingTables.insert(ctx.state.routing_tables, contact)
      state = %{ctx.state | routing_tables: tables}
      assert %{last_query_ms: nil} = entry(state, id)

      result = inbound_ping(state, @public_v4, 6_881, id, "q1")

      assert result.pending == %{}
      assert %{status: :good, last_query_ms: last_query} = entry(result, id)
      assert is_integer(last_query)
    end

    test "a known id claimed from a new address is a candidate; its silence costs the real node nothing",
         ctx do
      id = BEP42.generate(@public_v4, 7)
      real = %{id: id, ip: @public_v4, port: 6_881}
      tables = RoutingTables.insert(ctx.state.routing_tables, real)
      state = %{ctx.state | routing_tables: tables}

      result = inbound_ping(state, @public_v4, 7_000, id, "q1")
      assert %{ip: @public_v4, port: 6_881, failed_queries: 0} = entry(result, id)
      [{tid, %{type: :candidate_ping, node: %{port: 7_000}}}] = Map.to_list(result.pending)

      # Two silent probes in a row would make the real node bad if they
      # counted against it.
      {:noreply, once} = DHT.handle_info({:query_timeout, tid}, result)
      again = inbound_ping(once, @public_v4, 7_000, id, "q2")
      [{tid2, _pending}] = Map.to_list(again.pending)
      {:noreply, twice} = DHT.handle_info({:query_timeout, tid2}, again)

      assert %{status: :good, ip: @public_v4, port: 6_881, failed_queries: 0} = entry(twice, id)
    end

    test "per-IP and rate limits bound the probes a flood can cause", ctx do
      id = fn n -> <<n::160>> end

      # 127.0.0.0/8 is BEP 42-exempt and reachable under the test dial scope.
      state = inbound_ping(ctx.state, {127, 0, 0, 9}, 1, id.(1), "a")
      state = inbound_ping(state, {127, 0, 0, 9}, 2, id.(2), "b")
      state = inbound_ping(state, {127, 0, 0, 9}, 3, id.(3), "c")
      assert map_size(state.pending) == 2
      assert {:reply, %{dropped_per_ip: 1}, _} = stats(state)

      flooded =
        Enum.reduce(10..40, state, fn n, acc ->
          inbound_ping(acc, {127, 0, 0, n}, 6_881, id.(n), <<n>>)
        end)

      # 16 probes per second in all, the two above included.
      assert map_size(flooded.pending) == 16
      assert {:reply, %{candidates: 16, dropped_rate: 17}, _} = stats(flooded)
    end

    test "candidate pings never take more than a quarter of the query slots", ctx do
      pending =
        Map.new(1..64, fn n ->
          {<<n::16>>,
           %{type: :candidate_ping, node: contact(n, {127, 0, 1, n}, 1), timer_ref: make_ref()}}
        end)

      result = inbound_ping(%{ctx.state | pending: pending}, {127, 0, 2, 1}, 1, <<99::160>>, "q")

      assert map_size(result.pending) == 64
      assert {:reply, %{dropped_busy: 1}, _} = stats(result)
    end
  end

  describe "inbound query sources (IPv6, BEP 32)" do
    setup :dht_server

    test "an IPv6 candidate is verified into the v6 table only", ctx do
      id = BEP42.generate(@public_v6, 9)
      result = inbound_ping(ctx.state, @public_v6, 6_881, id, "q6")

      refute entry(result, id)
      [{tid, %{type: :candidate_ping, node: %{ip: @public_v6}}}] = Map.to_list(result.pending)

      verified = respond(result, @public_v6, 6_881, tid, id)

      assert %{status: :good, ip: @public_v6} =
               RoutingTable.find_entry(verified.routing_tables.v6, id)

      refute RoutingTable.find_entry(verified.routing_tables.v4, id)
      assert {:reply, %{routing_v6: 1, routing_v4: 0, verified: 1}, _} = stats(verified)
    end

    test "an unanswered IPv6 candidate leaves the v6 table empty", ctx do
      id = BEP42.generate(@public_v6, 10)
      result = inbound_ping(ctx.state, @public_v6, 6_881, id, "q6")
      [{tid, _pending}] = Map.to_list(result.pending)

      {:noreply, timed_out} = DHT.handle_info({:query_timeout, tid}, result)
      assert RoutingTable.node_count(timed_out.routing_tables.v6) == 0
      assert {:reply, %{unanswered: 1, candidates: 0}, _} = stats(timed_out)
    end
  end

  defp dht_server(_context) do
    {server, _ip, _port} = udp_socket()
    on_exit(fn -> :gen_udp.close(server) end)

    state = %DHT{
      socket_v4: server,
      socket_v6: nil,
      node_id: @local_id,
      routing_tables: RoutingTables.new(@local_id),
      tokens: Token.new()
    }

    %{state: state, server: server}
  end

  defp inbound_ping(state, ip, port, id, tid) do
    query = %{method: :ping, transaction_id: tid, node_id: id}

    {:noreply, state} =
      DHT.handle_info({:udp, state.socket_v4, ip, port, KRPC.encode_query(query)}, state)

    state
  end

  defp respond(state, ip, port, tid, id) do
    response = KRPC.encode_response(%{transaction_id: tid, node_id: id})
    {:noreply, state} = DHT.handle_info({:udp, state.socket_v4, ip, port, response}, state)
    state
  end

  defp stats(state), do: DHT.handle_call(:routing_stats, {self(), make_ref()}, state)

  defp entry(state, id), do: RoutingTables.find_entry(state.routing_tables, id)

  defp contact(n, ip, port), do: %{id: <<n::160>>, ip: ip, port: port}

  defp udp_socket do
    {:ok, socket} = :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])
    {:ok, {ip, port}} = :inet.sockname(socket)
    {socket, ip, port}
  end
end

defmodule Cycle3DhtCoverageTest do
  @moduledoc """
  Coverage for DHT (BEP 5) server callbacks that only run in degraded
  situations: a node whose UDP socket is gone, a lookup whose state no longer
  matches what the timer expects, a bootstrap router that does not resolve, and
  responses that arrive for transactions we already gave up on.

  The DHT process is a single GenServer shared by every torrent — one unhandled
  clause there takes peer discovery down for the whole client, so each of these
  paths must degrade rather than crash. The tests drive the callbacks directly
  with a synthetic state, which is also how `dht_coverage_batch_test.exs` works.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DHT.{KRPC, RoutingTables, Token}

  @local_id <<0::160>>
  @info_hash <<77::160>>

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

  describe "public API guards" do
    test "add_node/1 ignores anything that is not a compact contact" do
      assert :ok = DHT.add_node(:garbage)
      assert :ok = DHT.add_node(%{id: <<1, 2, 3>>, ip: {127, 0, 0, 1}, port: 6881})
    end

    test "terminate/2 without a routing table has nothing to persist" do
      assert :ok = DHT.terminate(:shutdown, :no_state)
    end
  end

  describe "handle_call/3 socket selection" do
    test "the legacy :udp_socket call defaults to the IPv4 socket" do
      {socket, _ip, _port} = udp_socket()
      state = dht_state(socket, RoutingTables.new(@local_id))

      assert {:reply, ^socket, ^state} = DHT.handle_call(:udp_socket, {self(), nil}, state)
    end

    test "an IPv6 request falls back to the IPv4 socket when there is no v6 bind" do
      {socket, _ip, _port} = udp_socket()
      state = dht_state(socket, RoutingTables.new(@local_id))

      # Under CGNAT+IPv6 the v6 socket is the useful one, but a v4-only host
      # must still answer rather than hand back nil.
      assert {:reply, ^socket, _} = DHT.handle_call({:udp_socket, :inet6}, {self(), nil}, state)
      assert {:reply, ^socket, _} = DHT.handle_call({:udp_socket, :other}, {self(), nil}, state)
    end
  end

  describe "incoming datagrams" do
    test "a uTP packet on the DHT port is handed to the uTP dispatcher" do
      {socket, ip, port} = udp_socket()
      state = dht_state(socket, RoutingTables.new(@local_id))

      # BEP 5 and uTP share UDP 6881; the first byte's version/type nibbles are
      # what tells them apart.
      utp = <<4::4, 1::4, 0, 1234::16, 0::32, 0::32, 1_048_576::32, 1::16, 0::16>>
      assert UTP.Packet.utp_packet?(utp)

      assert {:noreply, ^state} = DHT.handle_info({:udp, socket, ip, port, utp}, state)
    end

    test "a response for a transaction we already dropped is discarded" do
      {socket, ip, port} = udp_socket()
      state = dht_state(socket, RoutingTables.new(@local_id))

      packet =
        KRPC.encode_response(%{transaction_id: "zz", node_id: <<9::160>>, nodes: <<>>})

      assert {:noreply, new_state} = DHT.handle_info({:udp, socket, ip, port, packet}, state)
      assert new_state.pending == %{}
    end
  end

  describe "query timeouts" do
    test "a timeout for an unknown transaction changes nothing" do
      {socket, _ip, _port} = udp_socket()
      state = dht_state(socket, RoutingTables.new(@local_id))

      assert {:noreply, ^state} = DHT.handle_info({:query_timeout, "nope"}, state)
    end

    test "a timeout whose pending entry carries no node id is dropped" do
      {socket, _ip, _port} = udp_socket()

      state =
        dht_state(socket, RoutingTables.new(@local_id),
          pending: %{"aa" => %{type: :lookup, timer_ref: make_ref()}}
        )

      assert {:noreply, new_state} = DHT.handle_info({:query_timeout, "aa"}, state)
      assert new_state.pending == %{}
      assert new_state.routing_tables == state.routing_tables
    end
  end

  describe "lookup steps with inconsistent state" do
    test "a step for a lookup shaped like neither a peer nor a bootstrap lookup is ignored" do
      {socket, _ip, _port} = udp_socket()
      ref = make_ref()

      state =
        dht_state(socket, RoutingTables.new(@local_id), lookups: %{ref => %{unexpected: true}})

      assert {:noreply, ^state} = DHT.handle_info({:lookup_step, ref}, state)
    end

    test "an announce lookup that found peers proceeds straight to announce_peer" do
      {socket, _ip, _port} = udp_socket()
      {remote, remote_ip, remote_port} = udp_socket()
      close_on_exit([remote])

      ref = make_ref()

      lookup =
        announce_lookup(
          peers: [%Peer{ip: {192, 0, 2, 5}, port: 6881}],
          announce_nodes: %{
            {remote_ip, remote_port} => "tok0",
            # An IPv6 node sorts ahead of IPv4 — v6 is our reachable family.
            {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 6881} => "tok6"
          }
        )

      state = dht_state(socket, RoutingTables.new(@local_id), lookups: %{ref => lookup})

      assert {:noreply, new_state} = DHT.handle_info({:lookup_step, ref}, state)

      # The lookup is retired and a re-announce is armed (BEP 5 wants a refresh
      # roughly every 30 minutes so the swarm entry does not expire).
      refute Map.has_key?(new_state.lookups, ref)
      assert Map.has_key?(new_state.announce_timers, @info_hash)

      assert {:ok, {_ip, _port, packet}} = :gen_udp.recv(remote, 0, 1_000)
      assert {:ok, {:query, %{method: :announce_peer}}} = KRPC.decode(packet)
    end

    test "an announce lookup that ran out of retries still announces to what it has" do
      {socket, _ip, _port} = udp_socket()
      ref = make_ref()

      lookup = announce_lookup(peers: [], bootstrap_waits: 99, announce_nodes: %{})
      state = dht_state(socket, RoutingTables.new(@local_id), lookups: %{ref => lookup})

      assert {:noreply, new_state} = DHT.handle_info({:lookup_step, ref}, state)

      refute Map.has_key?(new_state.lookups, ref)
      assert Map.has_key?(new_state.announce_timers, @info_hash)
    end

    test "a re-announce cancels the timer it was scheduled by" do
      {socket, _ip, _port} = udp_socket()

      timer = Process.send_after(self(), :never, 60_000)

      state =
        dht_state(socket, RoutingTables.new(@local_id), announce_timers: %{@info_hash => timer})

      assert {:noreply, new_state} = DHT.handle_info({:reannounce, @info_hash, 6881}, state)

      # The old timer is replaced by the new lookup's own schedule.
      assert Enum.any?(new_state.lookups, fn {_ref, l} -> Map.get(l, :purpose) == :announce end)
      refute_received :never
    end
  end

  describe "bucket refresh and bootstrap" do
    test "a bucket with no known nodes cannot be refreshed" do
      {socket, _ip, _port} = udp_socket()
      state = dht_state(socket, RoutingTables.new(@local_id))

      assert {:noreply, _} = DHT.handle_info(:refresh_buckets, state)
    end

    test "a bootstrap router that does not resolve is skipped" do
      Application.put_env(
        :elixir_torrent,
        :dht,
        Keyword.put(
          Application.get_env(:elixir_torrent, :dht),
          :bootstrap_routers,
          [{"router.invalid.elixirtorrent.test", 6881}]
        )
      )

      {socket, _ip, _port} = udp_socket()
      state = dht_state(socket, RoutingTables.new(@local_id))

      assert {:noreply, new_state} = DHT.handle_info(:bootstrap, state)
      assert new_state.bootstrapped?
    end

    test "a bootstrap query on a closed socket is counted and dropped" do
      {socket, ip, port} = udp_socket()
      :ok = :gen_udp.close(socket)

      Application.put_env(
        :elixir_torrent,
        :dht,
        Keyword.put(
          Application.get_env(:elixir_torrent, :dht),
          :bootstrap_routers,
          [{:inet.ntoa(ip) |> List.to_string(), port}]
        )
      )

      state = dht_state(socket, RoutingTables.new(@local_id))

      capture_log(fn ->
        assert {:noreply, new_state} = DHT.handle_info(:bootstrap, state)
        assert new_state.bootstrapped?
      end)
    end
  end

  describe "packet handling never takes the node down" do
    test "a query that trips over corrupted server state is contained" do
      {socket, _ip, _port} = udp_socket()
      {remote, remote_ip, remote_port} = udp_socket()
      close_on_exit([remote])

      tokens = Token.new()
      token = Token.issue(tokens, remote_ip)

      # A peer-store entry with an address that is not an IP tuple: the node
      # must log and keep serving instead of crashing the DHT for every torrent.
      state =
        dht_state(socket, RoutingTables.new(@local_id),
          tokens: tokens,
          peer_store: %{@info_hash => [%Peer{ip: :unknown, port: 6881}]}
        )

      query =
        KRPC.encode_query(%{
          method: :get_peers,
          transaction_id: "q1",
          node_id: <<5::160>>,
          info_hash: @info_hash,
          token: token
        })

      log =
        capture_log(fn ->
          assert {:noreply, ^state} =
                   DHT.handle_info({:udp, socket, remote_ip, remote_port, query}, state)
        end)

      assert log =~ "packet_crash"
    end
  end

  ## helpers -----------------------------------------------------------------

  defp announce_lookup(opts) do
    %{
      ref: make_ref(),
      purpose: :announce,
      from: nil,
      hash: @info_hash,
      bt_port: 6881,
      shortlist: [],
      peers: Keyword.get(opts, :peers, []),
      announce_nodes: Keyword.get(opts, :announce_nodes, %{}),
      queried: MapSet.new(),
      bootstrap_waits: Keyword.get(opts, :bootstrap_waits, 0)
    }
  end

  defp dht_state(socket, tables, opts \\ []) do
    %DHT{
      socket_v4: socket,
      socket_v6: Keyword.get(opts, :socket_v6),
      node_id: @local_id,
      port: Keyword.get(opts, :port, 6881),
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

  defp udp_socket do
    {:ok, socket} = :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])
    {:ok, {ip, port}} = :inet.sockname(socket)
    on_exit(fn -> :gen_udp.close(socket) end)
    {socket, ip, port}
  end

  defp close_on_exit(sockets), do: on_exit(fn -> Enum.each(sockets, &:gen_udp.close/1) end)
end

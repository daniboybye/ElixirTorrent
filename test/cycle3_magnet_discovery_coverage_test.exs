defmodule Cycle3MagnetDiscoveryCoverageTest do
  @moduledoc """
  Coverage for the peer-discovery half of a BEP 9 magnet round.

  A magnet has no peer list of its own, so a round has to find peers before it
  can ask anyone for metadata. It queries trackers and the DHT in parallel and
  then decides how hard to keep digging in the DHT: `announce_peer` plants us on
  nearby nodes, but a `get_peers` immediately afterwards usually comes back
  empty because the announcement needs a propagation window. So the retries are
  staged — a few quick attempts, then either one deep attempt inline (when
  trackers gave us nothing and we have no other option) or a background deep
  attempt (when tracker peers already unblocked the round).

  The retry delays are read from application config so this test can collapse
  the wall clock without changing the retry shape.
  """
  use ExUnit.Case, async: false

  alias DHT.{Compact, KRPC, RoutingTables}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    previous_fetcher = Application.get_env(:elixir_torrent, :magnet_fetcher, [])
    previous_dht = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :magnet_fetcher, previous_fetcher)
      Application.put_env(:elixir_torrent, :dht, previous_dht)
    end)

    Application.put_env(:elixir_torrent, :magnet_fetcher,
      dht_retry_delays_ms: [0, 0],
      dht_deep_retry_delay_ms: 0
    )

    Application.put_env(
      :elixir_torrent,
      :dht,
      Keyword.merge(previous_dht, lookup_timeout_ms: 50, bootstrap_routers: [])
    )

    :ok
  end

  test "a trackerless magnet digs into the DHT inline" do
    hash = :crypto.strong_rand_bytes(20)
    # A node that knows nobody, so "the round found nothing" is guaranteed by
    # construction. Against the open DHT it is not: nodes exist that answer
    # get_peers for *any* info-hash with injected values, so a random hash can
    # and does come back with a peer.
    seed_only_dht_node(hash, start_fake_dht_node(hash, nil))

    magnet = %Magnet{hash: hash, trackers: [], display_name: "no-trackers"}

    assert {peers, 0, []} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
    assert peers == %{}

    # The round talked to the fake node and nobody else. Without this the test
    # silently degrades back into a live-network test if the isolation in
    # seed_only_dht_node/2 ever stops holding.
    assert RoutingTables.node_count(:sys.get_state(DHT).routing_tables) == 1

    # Nothing was deferred to the background: the inline deep retry already ran.
    refute Magnet.Fetcher.dht_background_pending?(hash)
  end

  test "tracker peers unblock the round and push the deep DHT dig into the background" do
    hash = :crypto.strong_rand_bytes(20)
    port = start_http_tracker(compact_peer_response())

    magnet = %Magnet{
      hash: hash,
      trackers: ["http://127.0.0.1:#{port}/announce"],
      display_name: "with-tracker"
    }

    assert {peers, 1, trackers} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})

    assert trackers == ["http://127.0.0.1:#{port}/announce"]
    assert Map.values(peers) == [%Peer{ip: {192, 0, 2, 9}, port: 6881}]
  end

  test "x.pe endpoints from the magnet itself are merged with what discovery found" do
    hash = :crypto.strong_rand_bytes(20)
    seed_only_dht_node(hash, start_fake_dht_node(hash, nil))

    magnet = %Magnet{
      hash: hash,
      trackers: [],
      x_pe_peers: [%Peer{ip: {198, 51, 100, 3}, port: 51_413}],
      display_name: "x-pe"
    }

    assert {peers, 1, []} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
    assert Map.values(peers) == [%Peer{ip: {198, 51, 100, 3}, port: 51_413}]
  end

  test "a peer the DHT returns on a quick retry ends the ladder and joins the round" do
    hash = :crypto.strong_rand_bytes(20)
    dht_peer = %Peer{ip: {203, 0, 113, 7}, port: 51_413}

    put_retry_ladder(dht_retry_delays_ms: [0])
    seed_only_dht_node(hash, start_fake_dht_node(hash, dht_peer))

    magnet = %Magnet{hash: hash, trackers: [], display_name: "dht-quick"}

    assert {peers, 1, []} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
    assert Map.values(peers) == [dht_peer]
  end

  test "with the quick ladder exhausted the deep dig is what finds the peer" do
    hash = :crypto.strong_rand_bytes(20)
    dht_peer = %Peer{ip: {203, 0, 113, 8}, port: 6_881}

    # An empty quick ladder is the "every quick attempt came back empty" case
    # collapsed to zero wall clock: `dht_peers_with_retry` falls straight through
    # to the inline deep retry, which is the branch that rescues a round when
    # BEP 5 peers only propagate after the quick window has closed.
    put_retry_ladder(dht_retry_delays_ms: [])
    seed_only_dht_node(hash, start_fake_dht_node(hash, dht_peer))

    magnet = %Magnet{hash: hash, trackers: [], display_name: "dht-deep"}

    assert {peers, 1, []} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
    assert Map.values(peers) == [dht_peer]

    # Deep ran inline, so nothing was left for the background task to redo.
    refute Magnet.Fetcher.dht_background_pending?(hash)
  end

  ## helpers -----------------------------------------------------------------

  defp put_retry_ladder(overrides) do
    fetcher = Application.get_env(:elixir_torrent, :magnet_fetcher, [])
    Application.put_env(:elixir_torrent, :magnet_fetcher, Keyword.merge(fetcher, overrides))

    dht = Application.get_env(:elixir_torrent, :dht, [])

    # The fake node answers immediately; this only bounds the failure case.
    Application.put_env(:elixir_torrent, :dht, Keyword.put(dht, :lookup_timeout_ms, 2_000))
  end

  # Replace the routing table with exactly one node, so the lookup's shortlist is
  # the fake node and nothing else — no queries fly at whatever real nodes this
  # host happened to restore from disk, and the lookup converges as soon as that
  # one node answers.
  #
  # The socket is swapped too. The DHT binds the fixed BitTorrent port with
  # SO_REUSEPORT, so if a real ElixirTorrent instance is running on this machine
  # the kernel hands it an arbitrary share of the datagrams sent to that port and
  # the fake node's replies never come back. An ephemeral socket is ours alone.
  defp seed_only_dht_node(hash, port) do
    previous = :sys.get_state(DHT)

    contact = %{id: hash, ip: {127, 0, 0, 1}, port: port}
    socket = private_dht_socket()

    :sys.replace_state(DHT, fn state ->
      tables = RoutingTables.insert(RoutingTables.new(state.node_id), contact)
      %{state | routing_tables: tables, bootstrapped?: true, socket_v4: socket, socket_v6: nil}
    end)

    on_exit(fn ->
      try do
        :sys.replace_state(DHT, fn state ->
          %{
            state
            | routing_tables: previous.routing_tables,
              bootstrapped?: previous.bootstrapped?,
              socket_v4: previous.socket_v4,
              socket_v6: previous.socket_v6
          }
        end)
      catch
        :exit, _ -> :ok
      end

      :gen_udp.close(socket)
    end)

    :ok
  end

  # Owned by the DHT process and armed the way its own sockets are, so the real
  # `handle_info({:udp, ...})` clause matches and re-arms it.
  defp private_dht_socket do
    {:ok, socket} = :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])
    :ok = :gen_udp.controlling_process(socket, Process.whereis(DHT))
    :ok = :inet.setopts(socket, active: :once)
    socket
  end

  # A minimal BEP 5 node on loopback that hands out `peer` to every get_peers,
  # or knows nobody when `peer` is nil. BEP 42 exempts loopback from the
  # node-id/IP check, so the real DHT accepts its responses as trusted.
  defp start_fake_dht_node(node_id, peer) do
    {:ok, socket} = :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    value = compact_value(peer)

    # A passive socket may only be read by its controlling process, so the node
    # waits to be handed ownership before its first recv.
    pid =
      spawn(fn ->
        receive do
          :owned -> fake_node_loop(socket, node_id, value)
        end
      end)

    :ok = :gen_udp.controlling_process(socket, pid)
    send(pid, :owned)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_udp.close(socket)
    end)

    port
  end

  defp fake_node_loop(socket, node_id, value) do
    case :gen_udp.recv(socket, 0, 10_000) do
      {:ok, {ip, port, packet}} ->
        with {:ok, {:query, query}} <- KRPC.decode(packet) do
          :gen_udp.send(socket, ip, port, fake_node_reply(query, node_id, value))
        end

        fake_node_loop(socket, node_id, value)

      {:error, _} ->
        :ok
    end
  end

  defp compact_value(nil), do: nil
  defp compact_value(%Peer{ip: ip, port: port}), do: Compact.encode_peer(ip, port)

  # BEP 5: a node with no peers for the info-hash answers with `nodes` instead
  # of `values`. Empty `nodes` is the honest "and I know nobody closer either",
  # which converges the lookup immediately instead of widening the shortlist.
  defp fake_node_reply(%{method: :get_peers} = query, node_id, nil) do
    KRPC.encode_response(%{
      transaction_id: query.transaction_id,
      node_id: node_id,
      token: "tok",
      nodes: <<>>
    })
  end

  defp fake_node_reply(%{method: :get_peers} = query, node_id, value) do
    KRPC.encode_response(%{
      transaction_id: query.transaction_id,
      node_id: node_id,
      token: "tok",
      values: [value]
    })
  end

  # ping / find_node / announce_peer: acknowledge without widening the shortlist.
  defp fake_node_reply(query, node_id, _value) do
    KRPC.encode_response(%{transaction_id: query.transaction_id, node_id: node_id})
  end

  # BEP 23 compact response: 6 bytes per IPv4 peer.
  defp compact_peer_response do
    Bento.encode!(%{
      "interval" => 1_800,
      "peers" => <<192, 0, 2, 9, 6881::16>>
    })
  end

  defp start_http_tracker(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid = spawn(fn -> serve(listen, body) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp serve(listen, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> respond(socket, body) end)
        serve(listen, body)

      {:error, _} ->
        :ok
    end
  end

  defp respond(socket, body) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _request} ->
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

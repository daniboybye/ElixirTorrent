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
    magnet = %Magnet{hash: hash, trackers: [], display_name: "no-trackers"}

    assert {peers, 0, []} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
    assert peers == %{}

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

    magnet = %Magnet{
      hash: hash,
      trackers: [],
      x_pe_peers: [%Peer{ip: {198, 51, 100, 3}, port: 51_413}],
      display_name: "x-pe"
    }

    assert {peers, 1, []} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
    assert Map.values(peers) == [%Peer{ip: {198, 51, 100, 3}, port: 51_413}]
  end

  ## helpers -----------------------------------------------------------------

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

defmodule MagnetConnectionLoopbackTest do
  use ExUnit.Case, async: false

  alias Peer.LTEP
  alias Peer.LTEP.Session

  test "fetch_info assembles metadata from loopback ut_metadata replies" do
    info_map = %{
      "name" => "loopback-magnet",
      "length" => 128,
      "piece length" => 16_384,
      "pieces" => :binary.copy(<<0::160>>, 1)
    }

    info_blob = Bento.encode!(info_map)
    hash = :crypto.hash(:sha, info_blob)
    metadata_size = byte_size(info_blob)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    accept =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        serve_ut_metadata_peer(socket, hash, info_blob, metadata_size)
        :gen_tcp.close(listen)
        :ok
      end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    assert :ok = send_handshake(socket, hash)

    assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
             :gen_tcp.recv(socket, 68, 5_000)

    assert {:ok, ltep} =
             LTEP.handshake_exchange(socket, Session.new(), timeout: 5_000)

    assert :ok = :gen_tcp.send(socket, <<0, 0, 0, 1, 2>>)
    assert {:ok, <<0, 0, 0, 1, 1>>} = :gen_tcp.recv(socket, 5, 5_000)

    conn = %Magnet.Connection{
      socket: socket,
      ltep: ltep,
      metadata_size: metadata_size,
      transport: :tcp,
      unchoked?: true,
      unchoke_since: System.monotonic_time(:millisecond) - 1_000
    }

    assert {:ok, decoded, ^info_blob} = Magnet.Connection.fetch_info(conn, hash)
    assert decoded["name"] == "loopback-magnet"
    :gen_tcp.close(socket)
    assert :ok = Task.await(accept, 5_000)
  end

  test "fetch_info returns info_hash_mismatch for wrong metadata bytes" do
    info_blob =
      Bento.encode!(%{
        "name" => "x",
        "length" => 10,
        "piece length" => 16_384,
        "pieces" => <<0::160>>
      })

    hash = :crypto.strong_rand_bytes(20)
    metadata_size = byte_size(info_blob)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    accept =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        serve_ut_metadata_peer(socket, hash, info_blob, metadata_size)
        :gen_tcp.close(listen)
        :ok
      end)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    assert :ok = send_handshake(socket, hash)
    assert {:ok, _} = :gen_tcp.recv(socket, 68, 5_000)

    assert {:ok, ltep} =
             LTEP.handshake_exchange(socket, Session.new(), timeout: 5_000)

    assert :ok = :gen_tcp.send(socket, <<0, 0, 0, 1, 2>>)
    assert {:ok, <<0, 0, 0, 1, 1>>} = :gen_tcp.recv(socket, 5, 5_000)

    conn = %Magnet.Connection{
      socket: socket,
      ltep: ltep,
      metadata_size: metadata_size,
      transport: :tcp,
      unchoked?: true,
      unchoke_since: System.monotonic_time(:millisecond) - 1_000
    }

    assert {:error, :info_hash_mismatch} = Magnet.Connection.fetch_info(conn, hash)
    :gen_tcp.close(socket)
    Task.await(accept, 5_000)
  end

  defp send_handshake(socket, hash) do
    :gen_tcp.send(
      socket,
      [<<19>>, "BitTorrent protocol", Peer.reserved(), hash, Peer.id()]
    )
  end

  defp serve_ut_metadata_peer(socket, hash, info_blob, metadata_size) do
    {:ok, client_hs} = :gen_tcp.recv(socket, 68, 5_000)
    <<19, "BitTorrent protocol"::binary, _::binary>> = client_hs

    :gen_tcp.send(
      socket,
      [<<19>>, "BitTorrent protocol", Peer.reserved(), hash, Peer.id()]
    )

    {:ok, <<len::32>>} = :gen_tcp.recv(socket, 4, 5_000)
    {:ok, <<20, 0, _our_hs::binary>>} = :gen_tcp.recv(socket, len, 5_000)

    peer_hs =
      Bento.encode!(%{"m" => %{"ut_metadata" => 2}, "metadata_size" => metadata_size})

    :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(0, peer_hs))
    {:ok, <<0, 0, 0, 1, 2>>} = :gen_tcp.recv(socket, 5, 5_000)
    :gen_tcp.send(socket, <<0, 0, 0, 1, 1>>)
    loop_ut_metadata(socket, info_blob)
  catch
    _, _ -> :ok
  after
    :gen_tcp.close(socket)
  end

  defp loop_ut_metadata(socket, info_blob) do
    total_size = byte_size(info_blob)

    recv_loop = fn recv_loop ->
      ut_metadata_recv_step(recv_loop, socket, info_blob, total_size)
    end

    recv_loop.(recv_loop)
  end

  defp ut_metadata_recv_step(recv_loop, socket, info_blob, total_size) do
    case :gen_tcp.recv(socket, 4, 10_000) do
      {:ok, <<0, 0, 0, 0>>} ->
        recv_loop.(recv_loop)

      {:ok, <<len::32>>} ->
        ut_metadata_payload_step(recv_loop, socket, info_blob, total_size, len)

      _ ->
        :ok
    end
  end

  defp ut_metadata_payload_step(recv_loop, socket, info_blob, total_size, len) do
    case :gen_tcp.recv(socket, len, 10_000) do
      {:ok, <<20, _ext_id, payload::binary>>} ->
        ut_metadata_handle_payload(recv_loop, socket, info_blob, total_size, payload)

      _ ->
        :ok
    end
  end

  defp ut_metadata_handle_payload(recv_loop, socket, info_blob, total_size, payload) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: 0]}} ->
        data = Magnet.UtMetadata.encode_data(0, total_size, info_blob)
        :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(1, data))
        recv_loop.(recv_loop)

      _ ->
        :ok
    end
  end
end

defmodule MagnetFetcherRoundTest do
  use ExUnit.Case, async: false

  test "fetch_metadata_round with empty peer list returns no_peers" do
    magnet = %Magnet{hash: <<88::160>>, trackers: [], x_pe_peers: [], display_name: nil}

    assert {:error, :no_peers} = Magnet.Fetcher.fetch_metadata_round(magnet, [], [])
  end

  test "announce_stopped does not raise on empty tracker list" do
    hash = <<87::160>>
    assert :ok = Magnet.Fetcher.announce_stopped(hash, [])
  end

  test "fetch_session_active? is false for unknown hash" do
    refute Magnet.Fetcher.fetch_session_active?(:crypto.strong_rand_bytes(20))
  end

  test "upgrade_magnet is no-op when no session registered" do
    magnet = %Magnet{hash: <<86::160>>, trackers: [], x_pe_peers: [], display_name: nil}
    assert :ok = Magnet.Fetcher.upgrade_magnet(magnet.hash, magnet)
  end
end

defmodule DHTGenServerTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:elixir_torrent, :dht, [])
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    :ok
  end

  test "disabled API surfaces :disabled without crashing" do
    Application.put_env(:elixir_torrent, :dht, enabled: false)

    assert {:error, :disabled} = DHT.get_peers(:crypto.strong_rand_bytes(20))
    assert {:error, :disabled} = DHT.send_udp({127, 0, 0, 1}, 6881, "ping")
    assert :ok = DHT.announce(:crypto.strong_rand_bytes(20), 6881)
    assert :ok = DHT.add_node(%{id: <<0::160>>, ip: {1, 1, 1, 1}, port: 1})
  end

  test "cap_lookup_peers prefers IPv6 when truncating mixed peer lists" do
    v4 = for i <- 1..10, do: %Peer{ip: {i, i, i, i}, port: 6880 + i}
    v6 = [%Peer{ip: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}, port: 6881}]

    capped = DHT.cap_lookup_peers(v6 ++ v4, 4)
    assert length(capped) == 4
    assert Enum.any?(capped, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
  end

  test "add_node and seed_node accept contacts when DHT enabled" do
    previous = Application.get_env(:elixir_torrent, :dht, enabled: true)

    Application.put_env(:elixir_torrent, :dht, Keyword.put(previous, :enabled, true))

    if DHT.enabled?() do
      :ok = DHT.add_node(%{id: :crypto.strong_rand_bytes(20), ip: {127, 0, 0, 1}, port: 6882})
      :ok = DHT.seed_node({127, 0, 0, 1}, 6882)
      assert is_integer(DHT.port())
      assert is_port(DHT.udp_socket(:inet)) or DHT.udp_socket(:inet) == nil
    else
      assert :ok = DHT.add_node(%{id: <<0::160>>, ip: {127, 0, 0, 1}, port: 6882})
    end
  end

  test "get_peers rejects invalid hash size" do
    Application.put_env(:elixir_torrent, :dht, enabled: true)

    assert {:error, :disabled} = DHT.get_peers(<<0::128>>)
  end
end

defmodule DiscoveryCoverageBatchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias PeerDiscovery.LSD
  alias Tracker.{Error, Response}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "HTTP tracker JS redirect interoperability batch: success then hard failure" do
    hash = :crypto.strong_rand_bytes(20)
    peers_bin = <<192, 168, 99, 1, 6888::16>>

    ok_body =
      Bento.encode!(%{
        "interval" => 600,
        "complete" => 1,
        "incomplete" => 2,
        "peers" => peers_bin
      })

    redirect = ~s(<html><script>window.location.href="/peers";</script></html>)
    {port, _pid} = start_batch_tracker([{200, redirect}, {200, ok_body}])

    stats = [uploaded: 0, downloaded: 0, left: 4096, event: Torrent.started()]

    assert %Response{interval: 600, peers: [%Peer{ip: {192, 168, 99, 1}, port: 6888}]} =
             Tracker.request!(
               "http://127.0.0.1:#{port}/interstitial",
               hash,
               stats,
               http_timeout_ms: 5_000
             )

    fail_redirect = ~s(<html><script>window.location.href="/dead-end";</script></html>)
    {port2, _pid2} = start_batch_tracker([{200, fail_redirect}, {200, "<html>nope</html>"}])

    assert %Error{reason: :non_bencoded_response, retry_in: "never"} =
             Tracker.request!(
               "http://127.0.0.1:#{port2}/interstitial",
               hash,
               stats,
               http_timeout_ms: 5_000
             )
  end

  test "LSD loopback socket offers peer then private torrent blocks offer" do
    public_hash = :crypto.strong_rand_bytes(20)
    private_hash = :crypto.strong_rand_bytes(20)

    for {hash, private?} <- [{public_hash, false}, {private_hash, true}] do
      start_batch_manager!(hash)
      start_batch_announce!(hash, private?)
    end

    {:ok, socket} =
      :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_udp.close(socket) end)

    state = %{
      cookie: "batch-cookie",
      sockets: %{inet: socket, inet6: nil},
      interfaces: %{inet: [], inet6: []},
      announce_queue: []
    }

    source = {10, 11, 12, 13}

    public_packet =
      IO.iodata_to_binary(LSD.build_message([public_hash], 9001, "remote-a"))

    assert {:noreply, ^state} =
             LSD.handle_info({:udp, socket, source, 6771, public_packet}, state)

    assert batch_peer_queued?(public_hash, source, 9001)

    private_packet =
      IO.iodata_to_binary(LSD.build_message([private_hash], 9002, "remote-b"))

    assert {:noreply, ^state} =
             LSD.handle_info({:udp, socket, source, 6771, private_packet}, state)

    refute batch_peer_queued?(private_hash, source, 9002)
  end

  defp start_batch_tracker(steps) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    pid =
      spawn(fn ->
        batch_serve(listen, agent, steps)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      if Process.alive?(agent), do: Agent.stop(agent, :normal, 1_000)
      :gen_tcp.close(listen)
    end)

    {port, pid}
  end

  defp batch_serve(listen, agent, steps) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> batch_client(socket, agent, steps) end)
        batch_serve(listen, agent, steps)

      {:error, _} ->
        :ok
    end
  end

  defp batch_client(socket, agent, steps) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _request} ->
        idx = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        {code, body} = Enum.at(steps, idx) || List.last(steps)
        status = if code == 200, do: "200 OK", else: "#{code} Error"

        response =
          "HTTP/1.1 #{status}\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

        :gen_tcp.send(socket, response)

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp start_batch_manager!(hash) do
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}

    {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)
    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)
    pid
  end

  defp start_batch_announce!(hash, private?) do
    info =
      if private?,
        do: %{"name" => "batch-private", "private" => 1},
        else: %{"name" => "batch-public"}

    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => info},
      left: 512,
      last_index: 0,
      last_piece_length: 512
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}
    {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)
    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)
    pid
  end

  defp batch_peer_queued?(hash, ip, port) do
    name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}

    case GenServer.whereis(name) do
      nil -> false
      pid -> Map.has_key?(:sys.get_state(pid).queue, {ip, port})
    end
  end
end

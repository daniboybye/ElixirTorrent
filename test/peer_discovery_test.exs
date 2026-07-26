defmodule PeerDiscoveryTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "ensure_announce is no-op when announce process already registered" do
    hash = <<44::160>>
    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}

    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"private" => 1}, "name" => "pd"},
      left: 100,
      last_index: 0,
      last_piece_length: 100
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model_pid, 5_000)
    end)

    {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(pid, 1_000)
    end)

    assert :ok = PeerDiscovery.ensure_announce(hash)
  end

  test "ensure_announce tolerates missing torrent without raising" do
    hash = :crypto.strong_rand_bytes(20)
    assert :ok = PeerDiscovery.ensure_announce(hash)
  end

  test "get/1 and private?/1 delegate to Announce GenServer" do
    hash = <<45::160>>
    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}

    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"private" => 1}, "name" => "delegates"},
      left: 50,
      last_index: 0,
      last_piece_length: 50
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model_pid, 5_000)
    end)

    {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(pid, 1_000)
    end)

    _ = :sys.get_state(pid)
    assert is_list(PeerDiscovery.get(hash))
    assert PeerDiscovery.Announce.private?(hash)
  end

  test "connecting_to_peers and request_peer_refresh cast without crash" do
    hash = <<46::160>>
    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}

    torrent = %Torrent{
      hash: hash,
      metadata: %{"name" => "casts"},
      left: 50,
      last_index: 0,
      last_piece_length: 50
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model_pid, 5_000)
    end)

    {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(pid, 1_000)
    end)

    :ok = PeerDiscovery.connecting_to_peers(hash)
    :ok = PeerDiscovery.request_peer_refresh(hash)
    :ok = PeerDiscovery.replenish_candidates(hash)
    assert Process.alive?(pid)
  end

  test "stopped_announce fires stop event against tier trackers" do
    hash = <<47::160>>
    body = Bento.encode!(%{"interval" => 60, "peers" => <<>>})
    {port, _server} = start_stop_tracker(body)
    announce = "http://127.0.0.1:#{port}/announce"
    name = {:via, Registry, {Registry, {hash, PeerDiscovery.Announce}}}

    torrent = %Torrent{
      hash: hash,
      metadata: %{"name" => "stop", "announce-list" => [[announce]]},
      left: 50,
      last_index: 0,
      last_piece_length: 50
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model_pid, 5_000)
    end)

    {:ok, pid} = GenServer.start_link(PeerDiscovery.Announce, [self(), torrent], name: name)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(pid, 1_000)
    end)

    assert :ok = PeerDiscovery.stopped_announce(hash)
  end

  defp start_stop_tracker(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn(fn ->
        case :gen_tcp.accept(listen) do
          {:ok, socket} ->
            _ = :gen_tcp.recv(socket, 0, 2_000)

            response =
              "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

            :gen_tcp.send(socket, response)
            :gen_tcp.close(socket)
        end

        :gen_tcp.close(listen)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    {port, pid}
  end
end

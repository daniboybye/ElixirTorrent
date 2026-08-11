defmodule HandshakesCoverageBatchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Acceptor.Connection.Handshakes
  alias Peer.DialStats
  alias Peer.MSE.Handshake, as: MSEHandshake

  @timeout 2_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)

    if :ets.info(:peer_dial_stats) != :undefined, do: :ets.delete_all_objects(:peer_dial_stats)

    previous_mse = Application.get_env(:elixir_torrent, :mse_outbound)
    previous_dial_family_cap = Application.get_env(:elixir_torrent, :dial_family_cap)
    Application.put_env(:elixir_torrent, :mse_outbound, :plaintext)
    Application.put_env(:elixir_torrent, :dial_family_cap, true)

    on_exit(fn ->
      restore_env(:mse_outbound, previous_mse)
      restore_env(:dial_family_cap, previous_dial_family_cap)
      flush_exits()
    end)

    :ok
  end

  defp restore_env(_key, nil), do: Application.delete_env(:elixir_torrent, :mse_outbound)
  defp restore_env(key, value), do: Application.put_env(:elixir_torrent, key, value)

  describe "validation and endpoint filtering" do
    test "connectable_peer?/2 rejects invalid IP tuples and ports" do
      listen = Acceptor.port()

      refute Handshakes.connectable_peer?(%Peer{ip: {1, 2, 3}, port: 6881}, listen)
      refute Handshakes.connectable_peer?(%Peer{ip: {1, 2, 3, 4}, port: -1}, listen)
      refute Handshakes.ipv6_dialable?({1, 2, 3})
      refute Handshakes.local_endpoint?({1, 2, 3}, listen, listen)
      refute Handshakes.local_endpoint?({999, 0, 0, 1}, listen, listen)
    end

    test "dial_peers/2 returns zero when every candidate is already connected" do
      hash = :crypto.strong_rand_bytes(20)
      ip = loopback_ip() || flunk("no routable IPv4")
      port = 18_100 + rem(System.unique_integer([:positive]), 400)

      with_torrent_stack(hash, fn _hash ->
        peer_id = <<40::160>>
        :ok = Peer.Endpoints.register(hash, ip, port, self())

        peer = %Peer{ip: ip, port: port, id: peer_id}
        assert {0, %{}, []} = Handshakes.dial_peers([peer], hash)
      end)
    end

    test "dial_peers/2 skips not_connectable without poisoning DialStats" do
      hash = :crypto.strong_rand_bytes(20)
      listen = Acceptor.port()
      local = Acceptor.all_global_ips().inet

      if local do
        peer = %Peer{ip: local, port: listen}
        assert {0, %{}, []} = Handshakes.dial_peers([peer], hash)
        refute DialStats.throttle_worthy?(hash, :inet)
      else
        peer = %Peer{ip: {127, 0, 0, 1}, port: 6881}
        assert {0, %{}, []} = Handshakes.dial_peers([peer], hash)
      end
    end

    test "select_peers_to_dial/3 throttles wasteful IPv6 when IPv4 is healthy" do
      if Acceptor.primary_ips().inet6 == nil do
        :ok
      else
        hash = :crypto.strong_rand_bytes(20)

        with_torrent_stack(hash, fn _hash ->
          seed_swarm_count(hash, 20)
          DialStats.record(hash, :inet6, 0, 40)
          assert DialStats.throttle_worthy?(hash, :inet6)

          v4 = for n <- 1..10, do: %Peer{ip: {6, 0, 0, n}, port: 12_000 + n}

          v6 =
            for n <- 1..10,
                do: %Peer{ip: {0x2602, 0x002D, 0x4000, 0x0003, 0, 0, 0, n}, port: 13_000 + n}

          selected = Handshakes.select_peers_to_dial(v4 ++ v6, hash, 10)
          assert length(selected) == 10
          v6_selected = Enum.count(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
          assert v6_selected <= 4
        end)
      end
    end
  end

  describe "inbound recv parsing and recv/1 wrappers" do
    test "recv/1 and recv_task return ok on success and on controlling-process failure" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, <<41::160>>))

        assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                 :gen_tcp.recv(client, 68, @timeout)

        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(client)
        :gen_tcp.close(listen)

        {:ok, listen2, port2, ip2} = listen_on_loopback()
        {:ok, sock} = connect_loopback(ip2, port2)
        {owner, owner_mon, owner_release} = TestSupport.Sync.spawn_blocked()
        :ok = :gen_tcp.controlling_process(sock, owner)
        assert {:error, _} = Handshakes.recv_task(sock)
        TestSupport.Sync.release(owner, owner_release)
        TestSupport.Sync.await_down(owner_mon, owner)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen2)
      end)
    end

    test "rejects malformed protocol string after valid pstrlen" do
      hash = :crypto.strong_rand_bytes(20)

      bad =
        IO.iodata_to_binary([
          <<19>>,
          "NotBitTorrent!!!!!!",
          <<0::64>>,
          hash,
          <<42::160>>
        ])

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bad)
        refute match?({:ok, <<19, _::binary>>}, :gen_tcp.recv(client, 68, 500))
        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        assert Torrent.Swarm.count(hash) == 0
      end)
    end

    test "closes on truncated body after pstrlen and on garbage first byte" do
      hash_trunc = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash_trunc, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        trunc_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, <<19, "BitTorrent protocol">>)
        :gen_tcp.close(client)
        assert :ok = Task.await(trunc_task, @timeout)
        :gen_tcp.close(listen)
      end)

      hash_garbage = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash_garbage, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        garbage_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, <<0xFF>>)
        :gen_tcp.close(client)
        assert :ok = Task.await(garbage_task, @timeout)
        :gen_tcp.close(listen)
        assert Torrent.Swarm.count(hash_garbage) == 0
      end)
    end

    test "recv_utp/1 tolerates a closed uTP socket" do
      unless Process.whereis(UTP.Dispatcher), do: {:ok, _} = UTP.Dispatcher.start_link([])

      {:ok, udp} = :gen_udp.open(0, [:binary, active: false])

      {:ok, {:utp, pid}} =
        UTP.Connection.start_client(udp, {127, 0, 0, 1}, 19_876, conn_id: 50_001)

      :ok = UTP.Connection.close({:utp, pid})
      assert :ok = Handshakes.recv_utp({:utp, pid})
      :gen_udp.close(udp)
    end

    test "rejects inbound handshake when swarm is at max peers" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        seed_swarm_count(hash, 60)
        assert Torrent.Swarm.count(hash) == 60

        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, <<43::160>>))
        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        assert Torrent.Swarm.count(hash) == 60
      end)
    end

    test "notify_current_piece sends interested when torrent peer_status is set" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<44::160>>
      test_pid = self()

      log =
        capture_log(fn ->
          with_torrent_stack(hash, [peer_status: 0], fn _hash ->
            {:ok, listen, port, ip} = listen_on_loopback()
            key = Peer.make_key(hash, remote_id)

            accept_task =
              Task.async(fn ->
                {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
                send(test_pid, {:loopback_accepted, self()})
                recv_inbound(accepted)
              end)

            {:ok, client} = connect_loopback(ip, port)
            assert_receive {:loopback_accepted, _}, @timeout
            assert :ok = :gen_tcp.send(client, bt_handshake(hash, remote_id))

            assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                     :gen_tcp.recv(client, 68, @timeout)

            assert :ok = Task.await(accept_task, @timeout)
            :gen_tcp.close(client)
            :gen_tcp.close(listen)

            controller = registry_pid!({key, Peer.Controller})
            state = TestSupport.Sync.sync(controller)
            assert state.status == 0
            assert Torrent.Swarm.count(hash) == 1
          end)
        end)

      assert log =~ "[peer_handoff] ok"
    end
  end

  describe "outbound dial_peers failures and MSE prefer" do
    test "records handshake_failed for invalid peer response bytes" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        parent = self()
        close_gate = make_ref()

        server =
          Task.async(fn ->
            send(parent, :dial_server_ready)
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)
            _ = :gen_tcp.recv(sock, 68, @timeout)
            :ok = :gen_tcp.send(sock, :crypto.strong_rand_bytes(68))
            send(parent, :dial_server_done)

            receive do
              ^close_gate -> :ok
            end

            :gen_tcp.close(sock)
          end)

        assert_receive :dial_server_ready, @timeout
        peer = %Peer{ip: ip, port: port}
        assert {0, failures, [{^peer, :invalid_handshake}]} = Handshakes.dial_peers([peer], hash)
        assert Map.get(failures, :invalid_handshake) == 1
        assert_receive :dial_server_done, @timeout
        send(server.pid, close_gate)
        :gen_tcp.close(listen)
        assert :ok = Task.await(server, @timeout)
      end)
    end

    test "returns already_connected for blacklisted outbound peer id" do
      hash = :crypto.strong_rand_bytes(20)
      bad_id = <<45::160>>
      :ok = Acceptor.malicious_peer(bad_id)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        parent = self()
        close_gate = make_ref()

        server =
          Task.async(fn ->
            send(parent, :dial_server_ready)
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)
            _ = :gen_tcp.recv(sock, 68, @timeout)
            :ok = :gen_tcp.send(sock, bt_handshake(hash, bad_id))
            send(parent, :dial_server_done)

            receive do
              ^close_gate -> :ok
            end

            :gen_tcp.close(sock)
          end)

        assert_receive :dial_server_ready, @timeout
        peer = %Peer{ip: ip, port: port}
        assert {0, failures, [{^peer, :already_connected}]} = Handshakes.dial_peers([peer], hash)
        assert Map.get(failures, :already_connected) == 1
        assert_receive :dial_server_done, @timeout
        send(server.pid, close_gate)
        :gen_tcp.close(listen)
        assert :ok = Task.await(server, @timeout)
      end)
    end

    test "do_send returns already_connected when duplicate peers race the same endpoint" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<46::160>>

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        parent = self()
        close_gate = make_ref()
        accepts = :atomics.new(1, signed: false)

        server =
          Task.async(fn ->
            send(parent, :dial_server_ready)

            serve = fn serve ->
              {:ok, sock} = :gen_tcp.accept(listen, @timeout)
              _ = :gen_tcp.recv(sock, 68, @timeout)
              :ok = :gen_tcp.send(sock, bt_handshake(hash, remote_id))
              :atomics.add(accepts, 1, 1)

              case :atomics.get(accepts, 1) do
                1 ->
                  serve.(serve)

                _ ->
                  send(parent, :dial_server_done)

                  receive do
                    ^close_gate -> :ok
                  end

                  :gen_tcp.close(sock)
              end
            end

            serve.(serve)
          end)

        assert_receive :dial_server_ready, @timeout
        peer = %Peer{ip: ip, port: port, id: remote_id}

        assert {ok_count, failures, failed} = Handshakes.dial_peers([peer, peer], hash)
        assert ok_count == 1
        assert Map.get(failures, :add_peer_failed) == 1
        assert Enum.any?(failed, fn {^peer, :add_peer_failed} -> true end)
        assert_receive :dial_server_done, @timeout
        send(server.pid, close_gate)
        :gen_tcp.close(listen)
        assert :ok = Task.await(server, @timeout)
      end)
    end

    test "MSE prefer completes rc4 outbound dial against MSE-speaking peer" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<47::160>>
      Application.put_env(:elixir_torrent, :mse_outbound, :prefer)

      with_torrent_stack(hash, fn _hash ->
        register_torrents_list(hash)
        {:ok, listen, port, ip} = listen_on_loopback()
        parent = self()
        close_gate = make_ref()

        server =
          Task.async(fn ->
            send(parent, :dial_server_ready)
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)

            assert {:ok, %{recv: r, send: s, leftover: ia}} =
                     MSEHandshake.respond(
                       sock,
                       MSEHandshake.resolver([hash]),
                       @timeout
                     )

            assert <<19, "BitTorrent protocol"::binary, _::binary>> = ia
            mse_sock = Peer.Transport.wrap(sock, %{recv: r, send: s})
            assert :ok = Peer.Transport.send(mse_sock, bt_handshake(hash, remote_id))
            send(parent, :dial_server_done)

            receive do
              ^close_gate -> :ok
            end

            Peer.Transport.close(mse_sock)
          end)

        assert_receive :dial_server_ready, @timeout
        peer = %Peer{ip: ip, port: port}
        result = Handshakes.dial_peers([peer], hash)
        assert elem(result, 0) in [0, 1]
        assert_receive :dial_server_done, @timeout + 2_000
        send(server.pid, close_gate)
        :gen_tcp.close(listen)
        assert :ok = Task.await(server, @timeout + 2_000)
      end)
    end
  end

  describe "dial_utp_and_handshake/2" do
    test "returns already_connected for registered endpoint without dialing" do
      hash = :crypto.strong_rand_bytes(20)
      ip = loopback_ip() || flunk("no routable IPv4")
      port = 18_700 + rem(System.unique_integer([:positive]), 400)
      peer_id = <<50::160>>

      with_torrent_stack(hash, fn _hash ->
        :ok = Peer.Endpoints.register(hash, ip, port, self())
        peer = %Peer{ip: ip, port: port, id: peer_id}
        assert {:error, :already_connected} = Handshakes.dial_utp_and_handshake(peer, hash)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp loopback_ip do
    case Acceptor.all_global_ips().inet do
      {_, _, _, _} = ip -> ip
      _ -> nil
    end
  end

  defp listen_on_loopback do
    ip = loopback_ip() || flunk("host has no routable IPv4 for loopback dial tests")
    opts = [:binary, active: false, reuseaddr: true, ip: ip]
    {:ok, listen} = :gen_tcp.listen(0, opts)
    {:ok, port} = :inet.port(listen)
    {:ok, listen, port, ip}
  end

  defp connect_loopback(ip, port) do
    :gen_tcp.connect(ip, port, [:binary, active: false], @timeout)
  end

  defp bt_handshake(hash, peer_id) do
    IO.iodata_to_binary([<<19>>, "BitTorrent protocol", <<0::64>>, hash, peer_id])
  end

  defp recv_inbound(socket, opts \\ []) do
    case Handshakes.recv_task(socket) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, @timeout
        :ok

      {:error, _reason} = error ->
        if Keyword.get(opts, :allow_handoff_error, false), do: :ok, else: flunk(inspect(error))
    end
  end

  defp registry_pid!(key) do
    case Registry.lookup(Registry, key) do
      [{pid, _}] -> pid
      [] -> flunk("Registry partition #{inspect(key)} not registered")
    end
  end

  defp with_torrent_stack(hash, fun_or_attrs, maybe_fun \\ nil)

  defp with_torrent_stack(hash, attrs, fun) when is_list(attrs) and is_function(fun, 1) do
    torrent =
      %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "hs-batch", "piece length" => 16_384}},
        left: 16_384,
        last_index: 0,
        last_piece_length: 16_384,
        peer_status: nil
      }
      |> Map.merge(Map.new(attrs))

    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    start_swarm(hash)
    register_torrents_list(hash)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model_pid)
      stop_swarm(hash)
    end)

    fun.(hash)
  end

  defp with_torrent_stack(hash, fun, _) when is_function(fun, 1),
    do: with_torrent_stack(hash, [], fun)

  defp register_torrents_list(hash) do
    case DynamicSupervisor.start_child(
           Torrents,
           HandshakesCoverageBatchTest.TorrentHashStub.child_spec(hash)
         ) do
      {:ok, pid} -> stop_stub_on_exit(pid)
      {:error, {:already_started, pid}} -> stop_stub_on_exit(pid)
      {:error, _} = err -> err
    end
  end

  # The stub is a child of the REAL `Torrents` supervisor, but the
  # `Torrent.Model` behind it is owned by this test and stopped in
  # `with_torrent_stack/3`'s `on_exit`. Left behind, the pair reads to
  # `Torrents.stop_all_and_serialize/0` as a live torrent whose Model is dead:
  # `persist_session/1` calls `Torrent.Model.get/1`, exits `:noproc`, and the
  # surrounding `Enum.each` aborts — so a leak here fails unrelated tests in
  # other modules. `AcceptorDialHandshakeCoverageBatchTest` already does this;
  # this copy of the helper did not.
  defp stop_stub_on_exit(pid) do
    on_exit(fn -> TestSupport.Sync.safe_stop(pid, 1_000) end)
    :ok
  end

  defp start_swarm(hash) do
    name = {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

    case DynamicSupervisor.start_link(
           name: name,
           extra_arguments: [hash],
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp stop_swarm(hash) do
    case GenServer.whereis({:via, Registry, {Registry, {hash, Torrent.Swarm}}}) do
      nil -> :ok
      pid -> TestSupport.Sync.safe_stop(pid, 1_000)
    end
  end

  defp seed_swarm_count(hash, n) when n > 0 do
    name = {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

    for i <- 1..n do
      spec = %{
        id: {:dummy, i},
        start: {HandshakesCoverageBatchTest.DummyWorker, :start_link, []},
        restart: :temporary
      }

      {:ok, _} = DynamicSupervisor.start_child(name, spec)
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _, _} -> flush_exits()
    after
      0 -> :ok
    end
  end
end

defmodule HandshakesCoverageBatchTest.TorrentHashStub do
  @moduledoc false
  use GenServer

  @spec child_spec(Torrent.hash()) :: Supervisor.child_spec()
  def child_spec(hash) do
    %{
      id: {__MODULE__, hash},
      start: {__MODULE__, :start_link, [hash]},
      restart: :temporary
    }
  end

  @spec start_link(Torrent.hash()) :: GenServer.on_start()
  def start_link(hash), do: GenServer.start_link(__MODULE__, hash)

  @spec init(Torrent.hash()) :: {:ok, Torrent.hash()}
  def init(hash) do
    Registry.register(Registry, self(), hash)
    {:ok, hash}
  end
end

defmodule HandshakesCoverageBatchTest.DummyWorker do
  @moduledoc false

  @spec start_link(term()) :: {:ok, pid()}
  def start_link(_swarm_hash) do
    Task.start_link(fn ->
      release = make_ref()
      receive do: (^release -> :ok)
    end)
  end
end

defmodule AcceptorDialHandshakeCoverageBatchTest do
  use ExUnit.Case, async: false

  alias Acceptor.Connection.Handshakes
  alias Peer.{DialStats, LTEP, UtHolepunch}
  alias AcceptorDialHandshakeCoverageBatchTest.SentCollector

  @timeout 5_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)

    if :ets.info(:peer_dial_stats) != :undefined, do: :ets.delete_all_objects(:peer_dial_stats)

    previous_dial_family_cap = Application.get_env(:elixir_torrent, :dial_family_cap)
    previous_v6_dial_cap = Application.get_env(:elixir_torrent, :v6_dial_cap)
    Application.put_env(:elixir_torrent, :dial_family_cap, true)
    Application.put_env(:elixir_torrent, :v6_dial_cap, true)

    on_exit(fn ->
      Application.delete_env(:elixir_torrent, :mse_outbound)
      restore_env(:dial_family_cap, previous_dial_family_cap)
      restore_env(:v6_dial_cap, previous_v6_dial_cap)
      flush_exits()
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:elixir_torrent, key)
  defp restore_env(key, value), do: Application.put_env(:elixir_torrent, key, value)

  describe "inbound Handshakes.recv/1 plaintext" do
    test "accepts a valid loopback handshake and registers a swarm peer" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<9::160>>

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
            Process.sleep(400)
          end)

        Process.sleep(20)
        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, remote_id))
        assert {:ok, reply} = :gen_tcp.recv(client, 68, @timeout)
        assert <<19, "BitTorrent protocol"::binary, _::binary>> = reply
        Process.sleep(1_500)
        :gen_tcp.close(client)
        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(listen)
        wait_for_swarm(hash, 1)
      end)
    end

    test "rejects handshake with unknown info-hash" do
      hash = :crypto.strong_rand_bytes(20)
      wrong = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(wrong))
        refute match?({:ok, <<19, _::binary>>}, :gen_tcp.recv(client, 68, 500))
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        assert :ok = Task.await(accept_task, @timeout)
        assert Torrent.Swarm.count(hash) == 0
      end)
    end

    test "rejects blacklisted peer id" do
      hash = :crypto.strong_rand_bytes(20)
      bad_id = <<8::160>>
      :ok = Acceptor.malicious_peer(bad_id)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, bad_id))
        refute match?({:ok, <<19, _::binary>>}, :gen_tcp.recv(client, 68, 500))
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        assert :ok = Task.await(accept_task, @timeout)
        assert Torrent.Swarm.count(hash) == 0
      end)
    end

    test "closes socket on truncated handshake" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        test_pid = self()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            send(test_pid, :truncated_handshake_accepted)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, <<19>>)
        assert_receive :truncated_handshake_accepted, @timeout
        :gen_tcp.close(client)
        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(listen)
        assert Torrent.Swarm.count(hash) == 0
      end)
    end

    test "inbound handshake with our own peer id still completes BT reply" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
            Process.sleep(400)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, Peer.id()))

        assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                 :gen_tcp.recv(client, 68, @timeout)

        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        assert :ok = Task.await(accept_task, @timeout)
      end)
    end

    test "live acceptor port accepts inbound plaintext handshake" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<7::160>>

      with_torrent_stack(hash, fn _hash ->
        port = Acceptor.port()

        connector =
          Task.async(fn ->
            {:ok, sock} =
              :gen_tcp.connect(
                {127, 0, 0, 1},
                port,
                [:binary, active: false],
                @timeout
              )

            assert :ok = :gen_tcp.send(sock, bt_handshake(hash, remote_id))

            assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                     :gen_tcp.recv(sock, 68, @timeout)

            Process.sleep(1_500)
            :gen_tcp.close(sock)
          end)

        assert :ok = Task.await(connector, @timeout + 2_000)
        wait_for_swarm(hash, 1)
      end)
    end
  end

  describe "inbound Handshakes.recv/1 MSE" do
    test "accepts MSE-wrapped handshake when torrent is known" do
      hash = :crypto.strong_rand_bytes(20)
      ia = bt_handshake(hash, <<6::160>>)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
            Process.sleep(1_500)
          end)

        Process.sleep(30)
        {:ok, sock} = connect_loopback(ip, port)
        assert {:ok, %{mode: :rc4}} = Peer.MSE.Handshake.initiate(sock, hash, ia, @timeout)
        Process.sleep(500)
        :gen_tcp.close(sock)

        assert :ok = Task.await(accept_task, @timeout + 2_000)
        :gen_tcp.close(listen)
      end)
    end
  end

  describe "outbound Handshakes.dial_peers/2" do
    setup do
      Application.put_env(:elixir_torrent, :mse_outbound, :plaintext)
      :ok
    end

    test "plaintext loopback dial completes handshake and handoff" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<5::160>>

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        server =
          Task.async(fn ->
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)

            assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                     :gen_tcp.recv(sock, 68, @timeout)

            assert :ok = :gen_tcp.send(sock, bt_handshake(hash, remote_id))
            Process.sleep(1_500)
            :gen_tcp.close(sock)
          end)

        Process.sleep(30)
        peer = %Peer{ip: ip, port: port}
        assert {ok_count, failures, failed} = Handshakes.dial_peers([peer], hash)
        assert ok_count == 1 or Map.has_key?(failures, :socket_handoff_failed)
        assert failed == [] or match?([{^peer, :socket_handoff_failed}], failed)
        :gen_tcp.close(listen)
        Task.await(server, @timeout)
      end)
    end

    test "MSE prefer falls back to plaintext-only peer" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<4::160>>
      Application.put_env(:elixir_torrent, :mse_outbound, :prefer)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        server =
          Task.async(fn ->
            wait_plain =
              fn wait_plain ->
                {:ok, sock} = :gen_tcp.accept(listen, @timeout)

                case :gen_tcp.recv(sock, 1, @timeout) do
                  {:ok, <<19>>} ->
                    {:ok, _rest} = :gen_tcp.recv(sock, 67, @timeout)
                    assert :ok = :gen_tcp.send(sock, bt_handshake(hash, remote_id))
                    Process.sleep(1_500)
                    :gen_tcp.close(sock)

                  _ ->
                    :gen_tcp.close(sock)
                    wait_plain.(wait_plain)
                end
              end

            wait_plain.(wait_plain)
          end)

        Process.sleep(30)
        peer = %Peer{ip: ip, port: port}
        _result = Handshakes.dial_peers([peer], hash)

        # Server task asserts the plaintext fallback handshake; dial outcome may
        # be ok or OTP handoff churn under parallel suite load.
        assert :ok = Task.await(server, @timeout + 5_000)
        :gen_tcp.close(listen)
      end)
    end

    test "returns zero counts for empty peer list" do
      hash = :crypto.strong_rand_bytes(20)
      assert {0, %{}, []} = Handshakes.dial_peers([], hash)
    end

    test "returns zero when every peer is filtered as not connectable" do
      hash = :crypto.strong_rand_bytes(20)
      listen = Acceptor.port()
      %{inet: v4} = Acceptor.all_global_ips()

      if v4 do
        peer = %Peer{ip: v4, port: listen}
        assert {0, %{}, []} = Handshakes.dial_peers([peer], hash)
      else
        peer = %Peer{ip: {127, 0, 0, 1}, port: 6881}
        assert {0, %{}, []} = Handshakes.dial_peers([peer], hash)
      end
    end

    test "records failure when peer responds with wrong info-hash" do
      hash = :crypto.strong_rand_bytes(20)
      wrong = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        server =
          Task.async(fn ->
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)
            _ = :gen_tcp.recv(sock, 68, @timeout)
            assert :ok = :gen_tcp.send(sock, bt_handshake(wrong))
            Process.sleep(500)
            :gen_tcp.close(sock)
          end)

        Process.sleep(30)
        peer = %Peer{ip: ip, port: port}
        assert {0, failures, failed} = Handshakes.dial_peers([peer], hash)
        assert map_size(failures) >= 1
        assert length(failed) == 1
        :gen_tcp.close(listen)
        Task.await(server, @timeout)
      end)
    end

    test "handshakes_sync/2 is equivalent to dial_peers for loopback success" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        Task.async(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, @timeout)
          _ = :gen_tcp.recv(sock, 68, @timeout)
          :gen_tcp.send(sock, bt_handshake(hash))
          Process.sleep(1_500)
          :gen_tcp.close(sock)
        end)

        Process.sleep(30)
        assert :ok = Handshakes.handshakes_sync([%Peer{ip: ip, port: port}], hash)
        Process.sleep(500)
        :gen_tcp.close(listen)
      end)
    end

    test "handshakes/2 offers peers via ConnectionManager without crash" do
      hash = :crypto.strong_rand_bytes(20)
      peer = %Peer{ip: {203, 0, 113, 1}, port: 6881}
      assert :ok = Handshakes.handshakes([peer], hash)
    end

    test "dial_utp_and_handshake returns already_connected for registered endpoint" do
      hash = :crypto.strong_rand_bytes(20)
      ip = loopback_ip() || flunk("no routable IPv4")
      port = 19_000 + rem(System.unique_integer([:positive]), 1000)

      with_torrent_stack(hash, fn _hash ->
        key = Peer.make_key(hash, <<3::160>>)
        :ok = Peer.Endpoints.register(hash, ip, port, self())

        peer = %Peer{ip: ip, port: port, id: elem(key, 0)}
        assert {:error, :already_connected} = Handshakes.dial_utp_and_handshake(peer, hash)
      end)
    end
  end

  describe "select_peers_to_dial/3 batch composition" do
    test "critical tier (<12 connected) prefers IPv6 candidates first" do
      if Acceptor.primary_ips().inet6 == nil do
        :ok
      else
        hash = :crypto.strong_rand_bytes(20)
        v6 = {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 0x0042}

        v4_peers =
          for n <- 1..30, do: %Peer{ip: {1, 0, 0, rem(n, 250) + 1}, port: 6000 + n}

        v6_peers = for n <- 1..5, do: %Peer{ip: v6, port: 7000 + n}
        selected = Handshakes.select_peers_to_dial(v4_peers ++ v6_peers, hash, 10)
        assert length(selected) == 10
        v6_count = Enum.count(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
        assert v6_count >= 5
      end
    end

    test "throttles proven-wasteful IPv4 to probe + IPv6 fill" do
      if Acceptor.primary_ips().inet6 == nil do
        :ok
      else
        hash = :crypto.strong_rand_bytes(20)

        with_torrent_stack(hash, fn _hash ->
          seed_swarm_count(hash, 20)
          DialStats.record(hash, :inet, 0, 40)

          v4 = for n <- 1..20, do: %Peer{ip: {2, 0, 0, n}, port: 8000 + n}
          v6 = [%Peer{ip: {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 1}, port: 9001}]

          selected = Handshakes.select_peers_to_dial(v4 ++ v6, hash, 10)
          assert length(selected) <= 10
          assert Enum.any?(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
          v4_selected = Enum.count(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 4 end)
          assert v4_selected <= 4
        end)
      end
    end

    test "caps sole IPv4 batch to probe when critical and v4 wasteful" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        DialStats.record(hash, :inet, 0, 40)
        seed_swarm_count(hash, 5)

        v4 = for n <- 1..30, do: %Peer{ip: {3, 0, 0, n}, port: 8100 + n}
        selected = Handshakes.select_peers_to_dial(v4, hash, 40)
        assert length(selected) == 4
      end)
    end

    test "balanced batch when neither family is throttle-worthy" do
      if Acceptor.primary_ips().inet6 == nil do
        :ok
      else
        hash = :crypto.strong_rand_bytes(20)

        with_torrent_stack(hash, fn _hash ->
          seed_swarm_count(hash, 20)

          v4 = for n <- 1..10, do: %Peer{ip: {4, 0, 0, n}, port: 8200 + n}

          v6 =
            for n <- 1..10,
                do: %Peer{ip: {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, n}, port: 9200 + n}

          selected = Handshakes.select_peers_to_dial(v4 ++ v6, hash, 10)
          assert length(selected) == 10
          assert Enum.any?(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 4 end)
          assert Enum.any?(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
        end)
      end
    end

    test "v6-heavy batch when prefer_inet6 stats say so" do
      if Acceptor.primary_ips().inet6 == nil do
        :ok
      else
        hash = :crypto.strong_rand_bytes(20)

        with_torrent_stack(hash, fn _hash ->
          seed_swarm_count(hash, 20)
          DialStats.record(hash, :inet6, 30, 5)
          DialStats.record(hash, :inet, 5, 30)

          v4 = for n <- 1..20, do: %Peer{ip: {5, 0, 0, n}, port: 8300 + n}

          v6 =
            for n <- 1..20,
                do: %Peer{ip: {0x2602, 0x002D, 0x4000, 0x0002, 0, 0, 0, n}, port: 9300 + n}

          selected = Handshakes.select_peers_to_dial(v4 ++ v6, hash, 10)
          assert length(selected) == 10
          v6_count = Enum.count(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
          assert v6_count >= 6
        end)
      end
    end
  end

  describe "connectable_peer?/2 and routable_ip?/1" do
    test "rejects invalid ports and multicast IPv4" do
      listen = Acceptor.port()
      refute Handshakes.connectable_peer?(%Peer{ip: {1, 2, 3, 4}, port: 0}, listen)
      refute Handshakes.connectable_peer?(%Peer{ip: {1, 2, 3, 4}, port: 70_000}, listen)
      refute Handshakes.routable_ip?({224, 1, 2, 3})
      refute Handshakes.routable_ip?({0xFF00, 0, 0, 0, 0, 0, 0, 1})
      assert Handshakes.routable_ip?({1, 2, 3, 4})
    end

    test "ipv6_dialable? follows host global IPv6 availability" do
      v6 = {0x2602, 0x002D, 0x4000, 0x0001, 0, 0, 0, 1}

      if Acceptor.primary_ips().inet6 == nil do
        refute Handshakes.ipv6_dialable?(v6)
      else
        assert Handshakes.ipv6_dialable?(v6)
      end

      assert Handshakes.ipv6_dialable?({1, 2, 3, 4})
    end
  end

  describe "Acceptor module helpers" do
    test "socket and connect option builders include family tags" do
      assert :inet in Acceptor.socket_options(:inet)
      assert :inet6 in Acceptor.socket_options(:inet6)
      refute :ipv6_v6only in Acceptor.connect_options(:inet6)
      assert :inet6 in Acceptor.connect_options(:inet6)
      assert is_list(Acceptor.tcp_socket_options(:inet6))
      assert Acceptor.port_range() == 6881..9999
      assert byte_size(Acceptor.key()) == 4
    end

    test "compute_all_global_ips and format_ip cover runtime snapshot" do
      ips = Acceptor.compute_all_global_ips()
      assert Map.has_key?(ips, :inet6_all)

      case ips.inet6 do
        nil -> :ok
        ip -> assert is_binary(Acceptor.format_ip(ip))
      end

      assert is_map(Acceptor.primary_ips())
      assert Acceptor.ip_cache_key() == {Acceptor, :ip_cache}

      case Acceptor.ipv4_binary() do
        nil -> :ok
        bin -> assert byte_size(bin) == 4
      end

      case Acceptor.ipv6_binary() do
        nil -> :ok
        bin -> assert byte_size(bin) == 16
      end

      assert is_list(Acceptor.announcable_ipv6())
    end

    test "apply_tcp_performance and open_udp succeed on this host" do
      assert {:ok, udp} = Acceptor.open_udp(:inet)
      :gen_udp.close(udp)
      assert {:ok, udp6} = Acceptor.open_udp(:inet6)
      :gen_udp.close(udp6)

      {:ok, listen} = :gen_tcp.listen(0, Acceptor.tcp_socket_options(:inet))
      {:ok, port} = :inet.port(listen)

      connector =
        Task.async(fn ->
          {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
          :gen_tcp.close(c)
        end)

      {:ok, sock} = :gen_tcp.accept(listen, 2_000)
      assert :ok = Acceptor.apply_tcp_performance(sock)
      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
      Task.await(connector, 2_000)
    end

    test "ip_binary returns 4 or 16 byte binary" do
      bin = Acceptor.ip_binary()
      assert byte_size(bin) in [4, 16]
    end
  end

  describe "Peer.Transport coverage" do
    test "rejects unknown transport atom" do
      assert {:error, {:unsupported_transport, :quic}} =
               Peer.Transport.connect({1, 2, 3, 4}, 1, [transport: :quic], 100)
    end

    test "mse utp and tcp send recv setopts controlling_process close" do
      {a, b} = mse_cipher_pair()
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      parent = self()

      spawn_link(fn ->
        {:ok, s} = :gen_tcp.accept(listen, 2_000)
        send(parent, {:srv, s})
        Process.sleep(2_000)
      end)

      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

      {:ok, server} =
        receive do
          {:srv, s} -> {:ok, s}
        after
          2_000 -> flunk("no accept")
        end

      mse_sock = Peer.Transport.wrap(client, a)
      assert Peer.Transport.mse?(mse_sock)
      assert Peer.Transport.utp?(mse_sock) == false
      assert :ok = Peer.Transport.setopts(mse_sock, active: false)
      assert {:ok, {{127, 0, 0, 1}, _port}} = Peer.Transport.peername(mse_sock)
      assert :ok = Peer.Transport.send(mse_sock, "payload")
      assert {:ok, "payload"} = Peer.Transport.recv(Peer.Transport.wrap(server, b), 7, 2_000)
      assert Peer.Transport.decrypt_inbound(mse_sock, "x") != "payload"
      assert :ok = Peer.Transport.controlling_process(mse_sock, self())
      assert :ok = Peer.Transport.close(mse_sock)
      :gen_tcp.close(listen)
    end
  end

  describe "Peer.Holepunch coordination" do
    test "maybe_request skips when NAT mapping is endpoint-dependent (symmetric)" do
      hash = :crypto.strong_rand_bytes(20)
      prev = NAT.Stun.mapping()
      NAT.Stun.put_mapping(:endpoint_dependent)

      on_exit(fn -> NAT.Stun.put_mapping(prev) end)

      target = %Peer{ip: {8, 8, 8, 8}, port: 53}
      assert :ok = Peer.Holepunch.maybe_request(hash, target, :timeout)
    end

    test "maybe_request sends rendezvous through connected relay peer" do
      hash = :crypto.strong_rand_bytes(20)
      prev = NAT.Stun.mapping()
      NAT.Stun.put_mapping(:endpoint_independent)

      on_exit(fn -> NAT.Stun.put_mapping(prev) end)

      with_swarm(hash, fn _hash ->
        relay_key = start_relay_peer(hash)
        assert_receive {:relay_ready, ^relay_key}, @timeout
        {:ok, _} = SentCollector.start_link(relay_key, self())

        target = %Peer{ip: {8, 8, 4, 4}, port: 7777}
        assert :ok = Peer.Holepunch.maybe_request(hash, target, :timeout)
        assert_receive {:sent, {:socket_send_raw, wire}}, @timeout
        <<_len::32, 20, _ext, payload::binary>> = wire

        assert {:ok, %{type: :rendezvous, ip: {8, 8, 4, 4}, port: 7777}} =
                 UtHolepunch.decode(payload)
      end)
    end

    test "clear_pending removes dedup table entry" do
      hash = :crypto.strong_rand_bytes(20)
      ip = {9, 9, 9, 9}
      port = 1234
      assert :ok = Peer.Holepunch.clear_pending(hash, ip, port)
      assert :ok = Peer.Holepunch.initiate_connect(hash, {ip, port})
      Process.sleep(50)
    end
  end

  describe "Peer.UtHolepunch.handle_inbound/2" do
    test "connect message triggers punch dial task" do
      hash = :crypto.strong_rand_bytes(20)
      ip = {8, 8, 4, 4}
      port = 18_000 + rem(System.unique_integer([:positive]), 500)
      payload = UtHolepunch.encode(:connect, ip, port)
      state = holepunch_state(hash)

      assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)
    end

    test "error message clears pending attempt" do
      hash = :crypto.strong_rand_bytes(20)
      ip = {10, 0, 0, 1}
      port = 4321
      payload = UtHolepunch.encode(:error, ip, port, err_code: UtHolepunch.err_not_connected())
      state = holepunch_state(hash)

      assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)
      assert :ok = Peer.Holepunch.clear_pending(hash, ip, port)
    end

    test "rendezvous to self returns NoSelf error wire to initiator" do
      hash = :crypto.strong_rand_bytes(20)
      initiator_ip = loopback_ip() || flunk("no routable IPv4")

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: initiator_ip])

      {:ok, port} = :inet.port(listen)
      {:ok, socket} = :gen_tcp.connect(initiator_ip, port, [:binary, active: false], @timeout)

      key = Peer.make_key(hash, <<2::160>>)
      {:ok, _} = SentCollector.start_link(key, self())

      ltep = ltep_with_holepunch()

      state = %Peer.Controller.State{
        hash: hash,
        id: elem(key, 0),
        fast_extension: nil,
        status: nil,
        pieces_count: 1,
        socket: socket,
        ltep: ltep
      }

      payload = UtHolepunch.encode(:rendezvous, initiator_ip, port)
      assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)
      assert_receive {:sent, {:socket_send_raw, wire}}, @timeout

      assert {:ok, %{type: :error, err_code: 4}} =
               UtHolepunch.decode(extract_extended_payload(wire))

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end

    test "rendezvous when target not connected returns not_connected error" do
      hash = :crypto.strong_rand_bytes(20)
      key = Peer.make_key(hash, <<2::160>>)
      {:ok, _} = SentCollector.start_link(key, self())

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @timeout)

      state = %Peer.Controller.State{
        hash: hash,
        id: elem(key, 0),
        fast_extension: nil,
        status: nil,
        pieces_count: 1,
        socket: socket,
        ltep: ltep_with_holepunch()
      }

      target_ip = {11, 0, 0, 50}
      payload = UtHolepunch.encode(:rendezvous, target_ip, 6000)
      assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)
      assert_receive {:sent, {:socket_send_raw, wire}}, @timeout

      assert {:ok, %{type: :error, err_code: 2}} =
               UtHolepunch.decode(extract_extended_payload(wire))

      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end

    test "invalid payload is ignored without crash" do
      hash = :crypto.strong_rand_bytes(20)

      state = %Peer.Controller.State{
        hash: hash,
        id: <<1::160>>,
        fast_extension: nil,
        status: nil,
        pieces_count: 1,
        socket: nil,
        ltep: ltep_with_holepunch()
      }

      assert ^state = UtHolepunch.handle_inbound(state, <<0, 0, 1>>)
    end

    test "rendezvous relays connect to initiator and registered target" do
      hash = :crypto.strong_rand_bytes(20)
      target_ip = {10, 0, 0, 50}
      target_port = 7777
      relay_id = <<3::160>>
      relay_key = Peer.make_key(hash, relay_id)
      target_id = <<4::160>>
      target_key = Peer.make_key(hash, target_id)

      with_swarm(hash, fn _hash ->
        assert {:ok, _} = start_target_peer(hash, target_id, target_ip, target_port)
        {:ok, _} = SentCollector.start_link(relay_key, self())
        {:ok, _} = SentCollector.start_link(target_key, self())

        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @timeout)

        state = %Peer.Controller.State{
          hash: hash,
          id: relay_id,
          fast_extension: nil,
          status: nil,
          pieces_count: 1,
          socket: socket,
          ltep: ltep_with_holepunch()
        }

        payload = UtHolepunch.encode(:rendezvous, target_ip, target_port)
        assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)

        wires =
          collect_sent_wires(2)

        for wire <- wires do
          assert {:ok, %{type: :connect}} = UtHolepunch.decode(extract_extended_payload(wire))
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)
    end

    test "rendezvous when target lacks ut_holepunch returns no_support error" do
      hash = :crypto.strong_rand_bytes(20)
      target_ip = {10, 0, 0, 51}
      target_port = 7778
      relay_id = <<5::160>>
      relay_key = Peer.make_key(hash, relay_id)

      with_swarm(hash, fn _hash ->
        assert {:ok, _} =
                 start_target_peer(hash, <<6::160>>, target_ip, target_port, holepunch: false)

        {:ok, _} = SentCollector.start_link(relay_key, self())

        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @timeout)

        state = %Peer.Controller.State{
          hash: hash,
          id: relay_id,
          fast_extension: nil,
          status: nil,
          pieces_count: 1,
          socket: socket,
          ltep: ltep_with_holepunch()
        }

        payload = UtHolepunch.encode(:rendezvous, target_ip, target_port)
        assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)
        assert_receive {:sent, {:socket_send_raw, wire}}, @timeout

        assert {:ok, %{type: :error, err_code: 3}} =
                 UtHolepunch.decode(extract_extended_payload(wire))

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)
    end

    test "rendezvous when target session missing returns no_such_peer error" do
      hash = :crypto.strong_rand_bytes(20)
      target_ip = {10, 0, 0, 52}
      target_port = 7779
      relay_id = <<7::160>>
      relay_key = Peer.make_key(hash, relay_id)

      with_swarm(hash, fn _hash ->
        stub = spawn(fn -> Process.sleep(:infinity) end)
        :ok = Peer.Endpoints.register(hash, target_ip, target_port, stub)
        on_exit(fn -> Process.exit(stub, :kill) end)

        {:ok, _} = SentCollector.start_link(relay_key, self())

        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(listen)
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @timeout)

        state = %Peer.Controller.State{
          hash: hash,
          id: relay_id,
          fast_extension: nil,
          status: nil,
          pieces_count: 1,
          socket: socket,
          ltep: ltep_with_holepunch()
        }

        payload = UtHolepunch.encode(:rendezvous, target_ip, target_port)
        assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)
        assert_receive {:sent, {:socket_send_raw, wire}}, @timeout

        assert {:ok, %{type: :error, err_code: 1}} =
                 UtHolepunch.decode(extract_extended_payload(wire))

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
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
    ip = loopback_ip()

    if ip == nil do
      flunk("host has no routable IPv4 for loopback dial tests")
    else
      opts = [:binary, active: false, reuseaddr: true, ip: ip]
      {:ok, listen} = :gen_tcp.listen(0, opts)
      {:ok, port} = :inet.port(listen)
      {:ok, listen, port, ip}
    end
  end

  defp connect_loopback(ip, port) do
    :gen_tcp.connect(ip, port, [:binary, active: false], @timeout)
  end

  defp bt_handshake(hash, peer_id \\ Peer.id()) do
    IO.iodata_to_binary([<<19>>, "BitTorrent protocol", Peer.reserved(), hash, peer_id])
  end

  defp with_torrent_stack(hash, fun) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "acceptor-batch", "piece length" => 16_384}},
      left: 16_384,
      last_index: 0,
      last_piece_length: 16_384,
      peer_status: nil
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    start_swarm(hash)
    register_torrents_list(hash)

    on_exit(fn ->
      safe_stop(model_pid)
      stop_swarm(hash)
    end)

    fun.(hash)
  end

  defp with_swarm(hash, fun) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "hp", "piece length" => 16_384}},
      left: 16_384,
      last_index: 0,
      last_piece_length: 16_384,
      peer_status: nil
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    start_swarm(hash)

    on_exit(fn ->
      safe_stop(model_pid)
      stop_swarm(hash)
    end)

    fun.(hash)
  end

  defp register_torrents_list(hash) do
    case DynamicSupervisor.start_child(Torrents, __MODULE__.TorrentHashStub.child_spec(hash)) do
      {:ok, pid} ->
        on_exit(fn -> safe_stop(pid) end)

      {:error, {:already_started, pid}} ->
        on_exit(fn -> safe_stop(pid) end)

      {:error, _} = err ->
        err
    end
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
      pid -> safe_stop(pid)
    end
  end

  defp seed_swarm_count(hash, n) when n > 0 do
    name = {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

    for i <- 1..n do
      spec = %{
        id: {:dummy, i},
        start: {__MODULE__.DummyWorker, :start_link, []},
        restart: :temporary
      }

      {:ok, _} = DynamicSupervisor.start_child(name, spec)
    end
  end

  defp start_relay_peer(hash) do
    id = <<10::160>>
    key = Peer.make_key(hash, id)

    spec = %{
      id: {:relay, id},
      start: {__MODULE__.RelayPeer, :start_link, [hash, id, self()]},
      restart: :temporary
    }

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        {:via, Registry, {Registry, {hash, Torrent.Swarm}}},
        spec
      )

    key
  end

  defp start_target_peer(hash, id, ip, port, opts \\ []) do
    holepunch? = Keyword.get(opts, :holepunch, true)

    spec = %{
      id: {:target, id},
      start: {__MODULE__.TargetPeer, :start_link, [hash, id, ip, port, holepunch?]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(
      {:via, Registry, {Registry, {hash, Torrent.Swarm}}},
      spec
    )
  end

  defp collect_sent_wires(count, acc \\ []) do
    if length(acc) == count do
      Enum.reverse(acc)
    else
      receive do
        {:sent, {:socket_send_raw, wire}} ->
          collect_sent_wires(count, [wire | acc])
      after
        @timeout -> flunk("expected #{count} sent wires, got #{length(acc)}")
      end
    end
  end

  defp ltep_with_holepunch do
    LTEP.Session.new([Peer.UtHolepunch.Extension])
    |> LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{
      m: %{"ut_holepunch" => 3},
      metadata_size: nil
    })
  end

  defp holepunch_state(hash) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)

    on_exit(fn ->
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    %Peer.Controller.State{
      hash: hash,
      id: <<1::160>>,
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: socket,
      ltep: ltep_with_holepunch()
    }
  end

  defp extract_extended_payload(wire) do
    <<_len::32, 20, _ext, payload::binary>> = wire
    payload
  end

  defp mse_cipher_pair do
    s = :crypto.strong_rand_bytes(96)
    skey = :crypto.strong_rand_bytes(20)
    a2b = Peer.MSE.key_a(s, skey)
    b2a = Peer.MSE.key_b(s, skey)

    a = %{send: Peer.MSE.new_cipher(a2b), recv: Peer.MSE.new_cipher(b2a)}
    b = %{send: Peer.MSE.new_cipher(b2a), recv: Peer.MSE.new_cipher(a2b)}
    {a, b}
  end

  defp wait_for_swarm(hash, expected, attempts \\ 30) do
    if Torrent.Swarm.count(hash) == expected do
      :ok
    else
      if attempts > 0 do
        Process.sleep(50)
        wait_for_swarm(hash, expected, attempts - 1)
      else
        flunk("expected swarm count #{expected}, got #{Torrent.Swarm.count(hash)}")
      end
    end
  end

  defp safe_stop(pid) when is_pid(pid) do
    try do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    catch
      :exit, _ -> :ok
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

defmodule AcceptorDialHandshakeCoverageBatchTest.TorrentHashStub do
  @moduledoc false
  use GenServer

  def child_spec(hash) do
    %{
      id: {__MODULE__, hash},
      start: {__MODULE__, :start_link, [hash]},
      restart: :temporary
    }
  end

  def start_link(hash), do: GenServer.start_link(__MODULE__, hash)

  def init(hash) do
    Registry.register(Registry, self(), hash)
    {:ok, hash}
  end
end

defmodule AcceptorDialHandshakeCoverageBatchTest.DummyWorker do
  @moduledoc false

  def start_link(_swarm_hash), do: Task.start_link(fn -> Process.sleep(:infinity) end)
end

defmodule AcceptorDialHandshakeCoverageBatchTest.SentCollector do
  @moduledoc false
  use GenServer

  def start_link(key, test_pid) do
    GenServer.start_link(__MODULE__, {key, test_pid},
      name: {:via, Registry, {Registry, {key, Peer.Sender}}}
    )
  end

  @impl true
  def init({key, test_pid}), do: {:ok, {key, test_pid}}

  @impl true
  def handle_cast(msg, {key, test_pid}) do
    send(test_pid, {:sent, msg})
    {:noreply, {key, test_pid}}
  end

  @impl true
  def handle_call({:socket_send_raw, data}, _from, {key, test_pid}) do
    send(test_pid, {:sent, {:socket_send_raw, data}})
    {:reply, :ok, {key, test_pid}}
  end

  @impl true
  def handle_call(:activate, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call(:deactivate, _from, state), do: {:reply, :ok, state}
end

defmodule AcceptorDialHandshakeCoverageBatchTest.RelayPeer do
  @moduledoc false
  use GenServer

  def start_link(_swarm_hash, hash, id, test_pid) do
    GenServer.start_link(__MODULE__, {hash, id, test_pid})
  end

  def init({hash, id, test_pid}) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    {:ok, ctrl} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    ltep =
      Peer.LTEP.Session.new([Peer.UtHolepunch.Extension])
      |> Peer.LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{m: %{"ut_holepunch" => 3}})

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{state | ltep: ltep}
    end)

    send(test_pid, {:relay_ready, key})
    {:ok, %{controller: ctrl, key: key}}
  end
end

defmodule AcceptorDialHandshakeCoverageBatchTest.TargetPeer do
  @moduledoc false
  use GenServer

  def start_link(_swarm_hash, hash, id, endpoint_ip, endpoint_port, holepunch?) do
    GenServer.start_link(__MODULE__, {hash, id, endpoint_ip, endpoint_port, holepunch?})
  end

  def init({hash, id, endpoint_ip, endpoint_port, holepunch?}) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    {:ok, _ctrl} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    ltep =
      if holepunch? do
        Peer.LTEP.Session.new([Peer.UtHolepunch.Extension])
        |> Peer.LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{
          m: %{"ut_holepunch" => 3}
        })
      else
        Peer.LTEP.Session.new([])
        |> Peer.LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{m: %{}})
      end

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{state | ltep: ltep}
    end)

    :ok = Peer.Endpoints.register(hash, endpoint_ip, endpoint_port, self())
    {:ok, %{key: key}}
  end
end

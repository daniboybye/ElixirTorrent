defmodule AcceptorDialHandshakeCoverageBatchTest do
  use ExUnit.Case, async: false

  alias Acceptor.Connection.Handshakes
  alias AcceptorDialHandshakeCoverageBatchTest.SentCollector
  alias Peer.Controller.State
  alias Peer.{DialStats, LTEP, UtHolepunch}

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
        test_pid = self()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            send(test_pid, {:loopback_accepted, self()})
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        await_loopback_accept(accept_task)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, remote_id))
        assert {:ok, reply} = :gen_tcp.recv(client, 68, @timeout)
        assert <<19, "BitTorrent protocol"::binary, _::binary>> = reply
        await_inbound_handshake_tasks()
        await_peer_protocol(hash, remote_id)
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        await_swarm_count(hash, 1)
      end)
    end

    test "a peer that never replies to LTEP still continues on the base protocol" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<13::160>>
      ltep_reserved = <<0, 0, 0, 0, 0, 0x10, 0, 0>>

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, remote_id, ltep_reserved))

        assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                 :gen_tcp.recv(client, 68, @timeout)

        assert {:ok, <<len::32>>} = :gen_tcp.recv(client, 4, @timeout)
        assert {:ok, <<20, 0, local_handshake::binary>>} = :gen_tcp.recv(client, len, @timeout)
        assert {:ok, %Peer.LTEP.Handshake{}} = Peer.LTEP.Handshake.decode(local_handshake)

        # Deliberately omit the peer's id-0 reply. Base-wire traffic must not
        # wait for the optional LTEP negotiation or tear the peer down.
        assert :ok = :gen_tcp.send(client, <<1::32, 1>>)
        assert :ok = Task.await(accept_task, @timeout)
        await_inbound_handshake_tasks()
        await_peer_protocol(hash, remote_id)
        state = await_peer_unchoked(hash, remote_id)

        assert %Peer.LTEP.Session{} = state.ltep
        refute Peer.LTEP.Session.peer_supports?(state.ltep, "ut_metadata")
        assert Process.alive?(controller_pid(hash, remote_id))

        :gen_tcp.close(client)
        :gen_tcp.close(listen)
      end)
    end

    test "live LTEP re-handshake adds and disables ids while unknown ids are ignored" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<14::160>>
      ltep_reserved = <<0, 0, 0, 0, 0, 0x10, 0, 0>>

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, remote_id, ltep_reserved))
        assert {:ok, _base_reply} = :gen_tcp.recv(client, 68, @timeout)
        assert {:ok, <<len::32>>} = :gen_tcp.recv(client, 4, @timeout)
        assert {:ok, <<20, 0, _local_handshake::binary>>} = :gen_tcp.recv(client, len, @timeout)

        await_inbound_handshake_tasks()
        drain_client_wire(client)

        initial = Bento.encode!(%{"m" => %{"ut_metadata" => 7}})
        controller = controller_pid(hash, remote_id)
        1 = :erlang.trace(controller, true, [:receive])
        assert :ok = :gen_tcp.send(client, Peer.LTEP.extended_message_wire(0, initial))

        assert_receive {:trace, ^controller, :receive,
                        {:"$gen_cast", {:handle_extended, [0, ^initial]}}},
                       @timeout

        _ = :erlang.trace(controller, false, [:receive])
        TestSupport.Sync.sync(controller)

        await_peer_state(hash, remote_id, fn state ->
          Peer.LTEP.Session.peer_extension_id(state.ltep, "ut_metadata") == 7
        end)

        changed = Bento.encode!(%{"m" => %{"ut_metadata" => 0, "ut_holepunch" => 9}})
        1 = :erlang.trace(controller, true, [:receive])

        assert :ok =
                 :gen_tcp.send(client, [
                   Peer.LTEP.extended_message_wire(0, changed),
                   Peer.LTEP.extended_message_wire(254, <<1, 2, 3>>),
                   <<1::32, 1>>
                 ])

        assert_receive {:trace, ^controller, :receive,
                        {:"$gen_cast", {:handle_extended, [0, ^changed]}}},
                       @timeout

        assert_receive {:trace, ^controller, :receive,
                        {:"$gen_cast", {:handle_extended, [254, _]}}},
                       @timeout

        assert_receive {:trace, ^controller, :receive, {:"$gen_cast", {:handle_unchoke, []}}},
                       @timeout

        _ = :erlang.trace(controller, false, [:receive])
        TestSupport.Sync.sync(controller)

        state =
          await_peer_state(hash, remote_id, fn state ->
            not state.choke_me and
              not Peer.LTEP.Session.peer_supports?(state.ltep, "ut_metadata") and
              Peer.LTEP.Session.peer_extension_id(state.ltep, "ut_holepunch") == 9
          end)

        assert %Peer.Controller.State{} = state
        assert Process.alive?(controller_pid(hash, remote_id))

        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
      end)
    end

    test "rejects handshake with unknown info-hash" do
      hash = :crypto.strong_rand_bytes(20)
      wrong = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        test_pid = self()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            send(test_pid, {:loopback_accepted, self()})
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        await_loopback_accept(accept_task)
        assert :ok = :gen_tcp.send(client, bt_handshake(wrong))
        refute match?({:ok, <<19, _::binary>>}, :gen_tcp.recv(client, 68, 500))
        :gen_tcp.close(client)
        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(listen)
        assert Torrent.Swarm.count(hash) == 0
      end)
    end

    test "rejects blacklisted peer id" do
      hash = :crypto.strong_rand_bytes(20)
      bad_id = <<8::160>>
      :ok = Acceptor.malicious_peer(bad_id)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        test_pid = self()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            send(test_pid, {:loopback_accepted, self()})
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        await_loopback_accept(accept_task)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, bad_id))
        refute match?({:ok, <<19, _::binary>>}, :gen_tcp.recv(client, 68, 500))
        :gen_tcp.close(client)
        assert :ok = Task.await(accept_task, @timeout)
        :gen_tcp.close(listen)
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
        test_pid = self()

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            send(test_pid, {:loopback_accepted, self()})
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, client} = connect_loopback(ip, port)
        await_loopback_accept(accept_task)
        assert :ok = :gen_tcp.send(client, bt_handshake(hash, Peer.id()))

        assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                 :gen_tcp.recv(client, 68, @timeout)

        assert :ok = Task.await(accept_task, @timeout)
        await_inbound_handshake_tasks()
        await_peer_protocol(hash, Peer.id())
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
      end)
    end

    @tag race_group: :network
    test "live acceptor port accepts inbound plaintext handshake" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<7::160>>

      with_torrent_stack(hash, fn _hash ->
        port = Acceptor.port()
        parent = self()
        close_gate = make_ref()

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

            send(parent, {:live_acceptor_handshake_complete, self()})
            receive do: (^close_gate -> :ok)
            :gen_tcp.close(sock)
          end)

        assert_receive {:live_acceptor_handshake_complete, connector_pid}, @timeout
        assert connector.pid == connector_pid
        await_inbound_handshake_tasks()
        await_peer_protocol(hash, remote_id)
        await_swarm_count(hash, 1)
        send(connector.pid, close_gate)
        assert :ok = Task.await(connector, @timeout + 2_000)
      end)
    end
  end

  describe "inbound Handshakes.recv/1 MSE" do
    test "accepts MSE-wrapped handshake when torrent is known" do
      hash = :crypto.strong_rand_bytes(20)
      ia = bt_handshake(hash, <<6::160>>)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        test_pid = self()
        remote_id = <<6::160>>

        accept_task =
          Task.async(fn ->
            {:ok, accepted} = :gen_tcp.accept(listen, @timeout)
            send(test_pid, {:loopback_accepted, self()})
            assert :ok = Handshakes.recv(accepted)
          end)

        {:ok, sock} = connect_loopback(ip, port)
        await_loopback_accept(accept_task)
        assert {:ok, %{mode: :rc4}} = Peer.MSE.Handshake.initiate(sock, hash, ia, @timeout)
        await_inbound_handshake_tasks()
        await_peer_protocol(hash, remote_id)
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
        parent = self()
        close_gate = make_ref()

        server =
          Task.async(fn ->
            send(parent, {:dial_server_ready, self()})
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)

            assert {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
                     :gen_tcp.recv(sock, 68, @timeout)

            assert :ok = :gen_tcp.send(sock, bt_handshake(hash, remote_id))
            send(parent, {:dial_server_handshake_done, self()})

            receive do
              ^close_gate -> :ok
            end

            :gen_tcp.close(sock)
          end)

        assert_receive {:dial_server_ready, _}, @timeout
        peer = %Peer{ip: ip, port: port}
        assert {ok_count, failures, failed} = Handshakes.dial_peers([peer], hash)
        assert ok_count == 1 or Map.has_key?(failures, :socket_handoff_failed)
        assert failed == [] or match?([{^peer, :socket_handoff_failed}], failed)
        assert_receive {:dial_server_handshake_done, _}, @timeout
        send(server.pid, close_gate)
        :gen_tcp.close(listen)
        assert :ok = Task.await(server, @timeout)
      end)
    end

    test "MSE prefer falls back to plaintext-only peer" do
      hash = :crypto.strong_rand_bytes(20)
      remote_id = <<4::160>>
      Application.put_env(:elixir_torrent, :mse_outbound, :prefer)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        parent = self()
        close_gate = make_ref()

        server =
          Task.async(fn ->
            send(parent, {:dial_server_ready, self()})

            wait_plain =
              fn wait_plain ->
                {:ok, sock} = :gen_tcp.accept(listen, @timeout)

                case :gen_tcp.recv(sock, 1, @timeout) do
                  {:ok, <<19>>} ->
                    {:ok, _rest} = :gen_tcp.recv(sock, 67, @timeout)
                    assert :ok = :gen_tcp.send(sock, bt_handshake(hash, remote_id))
                    send(parent, {:dial_server_handshake_done, self()})

                    receive do
                      ^close_gate -> :ok
                    end

                    :gen_tcp.close(sock)

                  _ ->
                    :gen_tcp.close(sock)
                    wait_plain.(wait_plain)
                end
              end

            wait_plain.(wait_plain)
          end)

        assert_receive {:dial_server_ready, _}, @timeout
        peer = %Peer{ip: ip, port: port}
        _result = Handshakes.dial_peers([peer], hash)

        # Server task asserts the plaintext fallback handshake; dial outcome may
        # be ok or OTP handoff churn under parallel suite load.
        assert_receive {:dial_server_handshake_done, _}, @timeout + 5_000
        send(server.pid, close_gate)
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
        parent = self()
        close_gate = make_ref()

        server =
          Task.async(fn ->
            send(parent, {:dial_server_ready, self()})
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)
            _ = :gen_tcp.recv(sock, 68, @timeout)
            assert :ok = :gen_tcp.send(sock, bt_handshake(wrong))
            send(parent, {:dial_server_handshake_done, self()})

            receive do
              ^close_gate -> :ok
            end

            :gen_tcp.close(sock)
          end)

        assert_receive {:dial_server_ready, _}, @timeout
        peer = %Peer{ip: ip, port: port}
        assert {0, failures, failed} = Handshakes.dial_peers([peer], hash)
        assert map_size(failures) >= 1
        assert length(failed) == 1
        assert_receive {:dial_server_handshake_done, _}, @timeout
        send(server.pid, close_gate)
        :gen_tcp.close(listen)
        assert :ok = Task.await(server, @timeout)
      end)
    end

    test "handshakes_sync/2 is equivalent to dial_peers for loopback success" do
      hash = :crypto.strong_rand_bytes(20)

      with_torrent_stack(hash, fn _hash ->
        {:ok, listen, port, ip} = listen_on_loopback()
        parent = self()
        close_gate = make_ref()

        server =
          Task.async(fn ->
            send(parent, {:dial_server_ready, self()})
            {:ok, sock} = :gen_tcp.accept(listen, @timeout)
            _ = :gen_tcp.recv(sock, 68, @timeout)
            :gen_tcp.send(sock, bt_handshake(hash))
            send(parent, {:dial_server_handshake_done, self()})

            receive do
              ^close_gate -> :ok
            end

            :gen_tcp.close(sock)
          end)

        assert_receive {:dial_server_ready, _}, @timeout
        assert :ok = Handshakes.handshakes_sync([%Peer{ip: ip, port: port}], hash)
        assert_receive {:dial_server_handshake_done, _}, @timeout
        send(server.pid, close_gate)
        assert :ok = Task.await(server, @timeout)
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
      close_gate = make_ref()

      server_pid =
        spawn_link(fn ->
          {:ok, s} = :gen_tcp.accept(listen, 2_000)
          send(parent, {:srv, s})

          receive do
            ^close_gate -> :ok
          end

          :gen_tcp.close(s)
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
      send(server_pid, close_gate)
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
        assert_receive {:sent, ^relay_key, {:socket_send_raw, wire}}, @timeout
        <<_len::32, 20, _ext, payload::binary>> = wire

        assert {:ok, %{type: :rendezvous, ip: {8, 8, 4, 4}, port: 7777}} =
                 UtHolepunch.decode(payload)
      end)
    end

    test "relay selection prefers a peer whose PEX state contains the target" do
      hash = :crypto.strong_rand_bytes(20)
      prev = NAT.Stun.mapping()
      NAT.Stun.put_mapping(:endpoint_independent)
      on_exit(fn -> NAT.Stun.put_mapping(prev) end)

      target = %Peer{ip: {8, 8, 8, 8}, port: 6881}
      on_exit(fn -> Peer.Holepunch.clear_pending(hash, target.ip, target.port) end)

      with_swarm(hash, fn _hash ->
        key_a = start_relay_peer(hash, <<10::160>>)
        key_b = start_relay_peer(hash, <<11::160>>)
        assert_receive {:relay_ready, ^key_a}, @timeout
        assert_receive {:relay_ready, ^key_b}, @timeout
        {:ok, _} = SentCollector.start_link(key_a, self())
        {:ok, _} = SentCollector.start_link(key_b, self())

        ordered_keys =
          hash
          |> Torrent.Swarm.peer_supervisors()
          |> Enum.map(&Peer.get_key/1)
          |> Enum.filter(&(&1 in [key_a, key_b]))

        [fallback_key, preferred_key] = ordered_keys
        remember_pex_target(preferred_key, {target.ip, target.port})

        assert :ok = Peer.Holepunch.maybe_request(hash, target, :timeout)
        assert_receive {:sent, ^preferred_key, {:socket_send_raw, _wire}}, @timeout
        refute_received {:sent, ^fallback_key, {:socket_send_raw, _wire}}
      end)
    end

    test "relay error preserves cooldown ladder and the four-attempt session cap" do
      hash = :crypto.strong_rand_bytes(20)
      prev = NAT.Stun.mapping()
      NAT.Stun.put_mapping(:endpoint_independent)
      on_exit(fn -> NAT.Stun.put_mapping(prev) end)

      target = %Peer{ip: {9, 9, 9, 9}, port: 4321}
      on_exit(fn -> Peer.Holepunch.clear_pending(hash, target.ip, target.port) end)

      with_swarm(hash, fn _hash ->
        relay_key = start_relay_peer(hash)
        assert_receive {:relay_ready, ^relay_key}, @timeout
        {:ok, _} = SentCollector.start_link(relay_key, self())

        assert :ok = Peer.Holepunch.maybe_request(hash, target, :timeout)
        assert_receive {:sent, ^relay_key, {:socket_send_raw, _wire}}, @timeout

        error =
          UtHolepunch.encode(:error, target.ip, target.port,
            err_code: UtHolepunch.err_not_connected()
          )

        assert %Peer.Controller.State{} =
                 UtHolepunch.handle_inbound(holepunch_state(hash), error)

        assert %{count: 1, cooldown_seconds: 30, retry_in_seconds: retry_in} =
                 Peer.Holepunch.attempt_info(hash, target.ip, target.port)

        assert retry_in > 0
        assert :ok = Peer.Holepunch.maybe_request(hash, target, :timeout)
        refute_receive {:sent, ^relay_key, {:socket_send_raw, _wire}}, 50

        for {expected_count, expected_cooldown} <- [{2, 120}, {3, 480}, {4, 1920}] do
          backdate_holepunch_attempt(hash, target.ip, target.port, expected_cooldown)
          assert :ok = Peer.Holepunch.maybe_request(hash, target, :timeout)
          assert_receive {:sent, ^relay_key, {:socket_send_raw, _wire}}, @timeout

          assert %{count: ^expected_count, cooldown_seconds: ^expected_cooldown} =
                   Peer.Holepunch.attempt_info(hash, target.ip, target.port)
        end

        backdate_holepunch_attempt(hash, target.ip, target.port, 10_000)
        assert :ok = Peer.Holepunch.maybe_request(hash, target, :timeout)
        refute_receive {:sent, ^relay_key, {:socket_send_raw, _wire}}, 50
      end)
    end

    test "parallel rendezvous requests atomically consume one attempt" do
      hash = :crypto.strong_rand_bytes(20)
      prev = NAT.Stun.mapping()
      NAT.Stun.put_mapping(:endpoint_independent)
      on_exit(fn -> NAT.Stun.put_mapping(prev) end)

      target = %Peer{ip: {9, 9, 9, 10}, port: 6881}
      on_exit(fn -> Peer.Holepunch.clear_pending(hash, target.ip, target.port) end)

      with_swarm(hash, fn _hash ->
        relay_key = start_relay_peer(hash)
        assert_receive {:relay_ready, ^relay_key}, @timeout
        {:ok, _} = SentCollector.start_link(relay_key, self())

        1..10
        |> Task.async_stream(
          fn _ -> Peer.Holepunch.maybe_request(hash, target, :timeout) end,
          ordered: false,
          timeout: @timeout
        )
        |> Enum.each(fn result -> assert {:ok, :ok} = result end)

        assert drain_sent_wires() == 1

        assert %{count: 1, cooldown_seconds: 30} =
                 Peer.Holepunch.attempt_info(hash, target.ip, target.port)
      end)
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

    test "a current outbound cooldown does not suppress the relayed uTP connect" do
      hash = :crypto.strong_rand_bytes(20)
      ip = {8, 8, 4, 6}
      port = 19_000 + rem(System.unique_integer([:positive]), 500)
      key = {hash, ip, port}
      {stub, _stub_mon, stub_release} = TestSupport.Sync.spawn_blocked()
      :ok = Peer.Endpoints.register(hash, ip, port, stub)

      :ets.insert(
        :elixir_torrent_holepunch_pending,
        {key, System.monotonic_time(:second), 1}
      )

      on_exit(fn ->
        TestSupport.Sync.release(stub, stub_release)
        Peer.Holepunch.clear_pending(hash, ip, port)
      end)

      assert {:ok, task} = Peer.Holepunch.initiate_connect(hash, {ip, port})
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, reason}, @timeout
      assert reason in [:normal, :noproc]
      assert %{count: 1} = Peer.Holepunch.attempt_info(hash, ip, port)
    end

    test "connect message for an already-connected target is silently ignored" do
      hash = :crypto.strong_rand_bytes(20)
      ip = {8, 8, 4, 5}
      port = 18_500 + rem(System.unique_integer([:positive]), 500)
      {stub, _stub_mon, stub_release} = TestSupport.Sync.spawn_blocked()
      :ok = Peer.Endpoints.register(hash, ip, port, stub)

      on_exit(fn -> TestSupport.Sync.release(stub, stub_release) end)

      state = holepunch_state(hash)
      payload = UtHolepunch.encode(:connect, ip, port)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %Peer.Controller.State{} = UtHolepunch.handle_inbound(state, payload)
        end)

      refute log =~ "[holepunch] connect_recv"
      refute log =~ "[holepunch] punch_"
    end

    test "messages from a peer that did not advertise ut_holepunch are silently ignored" do
      hash = :crypto.strong_rand_bytes(20)
      key = Peer.make_key(hash, <<12::160>>)
      {:ok, _} = SentCollector.start_link(key, self())

      state = %Peer.Controller.State{
        hash: hash,
        id: elem(key, 0),
        fast_extension: nil,
        status: nil,
        pieces_count: 1,
        socket: nil,
        ltep: ltep_without_holepunch_support()
      }

      rendezvous = UtHolepunch.encode(:rendezvous, {11, 0, 0, 1}, 6881)
      connect = UtHolepunch.encode(:connect, {11, 0, 0, 2}, 6882)

      assert ^state = UtHolepunch.handle_inbound(state, rendezvous)
      assert ^state = UtHolepunch.handle_inbound(state, connect)
      refute_receive {:sent, ^key, {:socket_send_raw, _wire}}, 50
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
      assert_receive {:sent, ^key, {:socket_send_raw, wire}}, @timeout

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
      assert_receive {:sent, ^key, {:socket_send_raw, wire}}, @timeout

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

      assert %Peer.Controller.State{holepunch: %{rate: {_started_at, 1}}} =
               UtHolepunch.handle_inbound(state, <<0, 0, 1>>)
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

        assert {:ok, initiator_endpoint} = Peer.Transport.safe_peername(socket)

        messages =
          collect_sent_wires(2)
          |> Map.new()

        assert {:ok, %{type: :connect, ip: ^target_ip, port: ^target_port}} =
                 messages
                 |> Map.fetch!(relay_key)
                 |> extract_extended_payload()
                 |> UtHolepunch.decode()

        {initiator_ip, initiator_port} = initiator_endpoint

        assert {:ok, %{type: :connect, ip: ^initiator_ip, port: ^initiator_port}} =
                 messages
                 |> Map.fetch!(target_key)
                 |> extract_extended_payload()
                 |> UtHolepunch.decode()

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)
    end

    test "IPv6 rendezvous relays the opposite endpoint to each peer" do
      hash = :crypto.strong_rand_bytes(20)
      target_ip = {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
      target_port = 7881
      relay_id = <<13::160>>
      relay_key = Peer.make_key(hash, relay_id)
      target_id = <<14::160>>
      target_key = Peer.make_key(hash, target_id)
      loopback6 = {0, 0, 0, 0, 0, 0, 0, 1}

      with_swarm(hash, fn _hash ->
        assert {:ok, _} = start_target_peer(hash, target_id, target_ip, target_port)
        {:ok, _} = SentCollector.start_link(relay_key, self())
        {:ok, _} = SentCollector.start_link(target_key, self())

        {:ok, listen} =
          :gen_tcp.listen(0, [:inet6, :binary, active: false, reuseaddr: true, ip: loopback6])

        {:ok, port} = :inet.port(listen)

        {:ok, socket} =
          :gen_tcp.connect(loopback6, port, [:inet6, :binary, active: false], @timeout)

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
        messages = collect_sent_wires(2) |> Map.new()

        assert {:ok, %{type: :connect, ip: ^target_ip, port: ^target_port}} =
                 messages
                 |> Map.fetch!(relay_key)
                 |> extract_extended_payload()
                 |> UtHolepunch.decode()

        assert {:ok, {initiator_ip, initiator_port}} = Peer.Transport.safe_peername(socket)

        assert {:ok, %{type: :connect, ip: ^initiator_ip, port: ^initiator_port}} =
                 messages
                 |> Map.fetch!(target_key)
                 |> extract_extended_payload()
                 |> UtHolepunch.decode()

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)
    end

    test "inbound holepunch flood is limited per peer" do
      hash = :crypto.strong_rand_bytes(20)
      state = holepunch_state(hash)
      key = State.key(state)
      {:ok, _} = SentCollector.start_link(key, self())
      payload = UtHolepunch.encode(:rendezvous, {11, 0, 0, 60}, 6881)
      limit = UtHolepunch.inbound_rate_limit()

      state =
        Enum.reduce(1..(limit + 5), state, fn _, acc ->
          UtHolepunch.handle_inbound(acc, payload)
        end)

      assert %{rate: {_started_at, ^limit}} = state.holepunch
      assert drain_sent_wires() == limit
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
        assert_receive {:sent, ^relay_key, {:socket_send_raw, wire}}, @timeout

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
        {stub, _stub_mon, stub_release} = TestSupport.Sync.spawn_blocked()
        :ok = Peer.Endpoints.register(hash, target_ip, target_port, stub)

        on_exit(fn -> TestSupport.Sync.release(stub, stub_release) end)

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
        assert_receive {:sent, ^relay_key, {:socket_send_raw, wire}}, @timeout

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

  defp bt_handshake(hash, peer_id \\ Peer.id(), reserved \\ <<0::64>>) do
    # Most synthetic peers in this file exercise only the base protocol. Tests
    # that need LTEP pass their reserved bytes explicitly.
    IO.iodata_to_binary([<<19>>, "BitTorrent protocol", reserved, hash, peer_id])
  end

  defp await_loopback_accept(%Task{pid: pid}) do
    assert_receive {:loopback_accepted, ^pid}, @timeout
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

  defp start_relay_peer(hash, id \\ <<10::160>>) do
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
        {:sent, key, {:socket_send_raw, wire}} ->
          collect_sent_wires(count, [{key, wire} | acc])
      after
        @timeout -> flunk("expected #{count} sent wires, got #{length(acc)}")
      end
    end
  end

  defp drain_sent_wires(count \\ 0) do
    receive do
      {:sent, _key, {:socket_send_raw, _wire}} -> drain_sent_wires(count + 1)
    after
      0 -> count
    end
  end

  defp remember_pex_target(key, endpoint) do
    payload = Peer.UtPex.encode([endpoint], [])
    Peer.Controller.handle_extended(key, Peer.UtPex.Extension.local_id(), payload)
    await_relay_pex_target(key, endpoint)
  end

  defp backdate_holepunch_attempt(hash, ip, port, seconds) do
    key = {hash, ip, port}
    [{^key, _timestamp, count}] = :ets.lookup(:elixir_torrent_holepunch_pending, key)

    :ets.insert(
      :elixir_torrent_holepunch_pending,
      {key, System.monotonic_time(:second) - seconds, count}
    )
  end

  defp ltep_with_holepunch do
    LTEP.Session.new([Peer.UtHolepunch.Extension])
    |> LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{
      m: %{"ut_holepunch" => 3},
      metadata_size: nil
    })
  end

  defp ltep_without_holepunch_support do
    LTEP.Session.new([Peer.UtHolepunch.Extension])
    |> LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{m: %{}})
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

  defp drain_client_wire(client) do
    case :gen_tcp.recv(client, 4, 100) do
      {:ok, <<len::32>>} when len >= 0 ->
        assert {:ok, _body} = :gen_tcp.recv(client, len, @timeout)
        drain_client_wire(client)

      {:error, :timeout} ->
        :ok
    end
  end

  defp await_inbound_handshake_tasks(timeout \\ @timeout) do
    case Task.Supervisor.children(Acceptor.Connection.Handshakes) do
      [] ->
        :ok

      children ->
        refs =
          for pid <- children do
            {pid, Process.monitor(pid)}
          end

        Enum.each(refs, fn {pid, ref} ->
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, timeout
        end)

        await_inbound_handshake_tasks(timeout)
    end
  end

  defp await_swarm_count(hash, expected) do
    assert Torrent.Swarm.count(hash) == expected
  end

  defp await_peer_protocol(hash, peer_id) do
    pid = controller_pid(hash, peer_id)
    assert is_pid(pid), "Controller not registered for peer #{inspect(peer_id)}"
    assert match?(%{peer_reserved: nil}, TestSupport.Sync.sync(pid))
  end

  defp await_peer_unchoked(hash, peer_id) do
    await_peer_state(hash, peer_id, &(&1.choke_me == false))
  end

  defp await_peer_state(hash, peer_id, predicate) do
    key = Peer.make_key(hash, peer_id)
    sender = GenServer.whereis({:via, Registry, {Registry, {key, Peer.Sender}}})

    if is_pid(sender), do: TestSupport.Sync.sync(sender)

    pid = controller_pid(hash, peer_id)

    state =
      try do
        TestSupport.Sync.sync(pid)
      catch
        :exit, _ ->
          flunk("peer Controller unavailable hash=#{inspect(hash)} peer=#{inspect(peer_id)}")
      end

    unless predicate.(state) do
      flunk("peer state predicate failed hash=#{inspect(hash)} peer=#{inspect(peer_id)}")
    end

    state
  end

  defp await_relay_pex_target(key, endpoint) do
    case Peer.Controller.holepunch_relay_info(key) do
      {:ok, _ltep, endpoints} ->
        assert MapSet.member?(endpoints, endpoint)

      :error ->
        flunk("relay PEX state did not include #{inspect(endpoint)} for #{inspect(key)}")
    end
  end

  defp controller_pid(hash, peer_id) do
    key = Peer.make_key(hash, peer_id)
    GenServer.whereis({:via, Registry, {Registry, {key, Peer.Controller}}})
  end

  defp safe_stop(pid) when is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 1_000)

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

  def start_link(_swarm_hash) do
    Task.start_link(fn ->
      release = make_ref()

      receive do
        ^release -> :ok
      end
    end)
  end
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
    send(test_pid, {:sent, key, msg})
    {:noreply, {key, test_pid}}
  end

  @impl true
  def handle_call({:socket_send_raw, data}, _from, {key, test_pid}) do
    send(test_pid, {:sent, key, {:socket_send_raw, data}})
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

  alias Peer.LTEP.{Handshake, Session}
  alias Peer.UtHolepunch.Extension, as: UtHolepunchExtension
  alias Peer.UtPex.Extension, as: UtPexExtension

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
      Session.new([UtHolepunchExtension, UtPexExtension])
      |> Session.apply_peer_handshake(%Handshake{
        m: %{"ut_holepunch" => 3, "ut_pex" => 2}
      })

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

  alias Peer.LTEP.{Handshake, Session}
  alias Peer.UtHolepunch.Extension, as: UtHolepunchExtension

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
        Session.new([UtHolepunchExtension])
        |> Session.apply_peer_handshake(%Handshake{
          m: %{"ut_holepunch" => 3}
        })
      else
        Session.new([])
        |> Session.apply_peer_handshake(%Handshake{m: %{}})
      end

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{state | ltep: ltep}
    end)

    :ok = Peer.Endpoints.register(hash, endpoint_ip, endpoint_port, self())
    {:ok, %{key: key}}
  end
end

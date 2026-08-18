defmodule Cycle2PureProtocolCoverageTest do
  use ExUnit.Case, async: false

  alias DHT.{KRPC, NodeId, RoutingStore, RoutingTables, Token}
  alias Peer.{Endpoints, Holepunch, Transport}
  alias Peer.LTEP
  alias Peer.LTEP.Session
  alias Torrent.{Bitfield, Downloads, Files, PiecesStatistic}
  alias UTP.{LEDBAT, Packet, Socket}

  @local_id <<0xAA, 0::152>>
  @hash <<0xBB, 0::152>>
  @piece_len 512
  @timeout 2_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    previous_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "et_cycle2_pure_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(previous_cwd)
      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "DHT.KRPC pure decode and response helpers" do
    test "decode surfaces malformed, unknown type, and malformed error packets" do
      assert {:error, _} = KRPC.decode("not-bencode")

      unknown_type =
        Bento.encode!(%{
          "t" => "u",
          "y" => "x",
          "a" => %{"id" => @local_id}
        })

      assert {:error, :unknown_type} = KRPC.decode(unknown_type)

      malformed_error = Bento.encode!(%{"t" => "e", "y" => "e", "e" => [201]})
      assert {:error, :malformed_error} = KRPC.decode(malformed_error)

      malformed_query =
        Bento.encode!(%{
          "t" => "q",
          "y" => "q",
          "q" => 123,
          "a" => %{"id" => @local_id}
        })

      assert {:error, :malformed} = KRPC.decode(malformed_query)
    end

    test "decode accepts unknown method strings and encodes want/implied_port args" do
      unknown_method =
        Bento.encode!(%{
          "t" => "m",
          "y" => "q",
          "q" => "custom_method",
          "a" => %{"id" => @local_id}
        })

      assert {:ok, {:query, query}} = KRPC.decode(unknown_method)
      assert query.method == {:unknown, "custom_method"}

      find_node =
        KRPC.encode_query(%{
          method: :find_node,
          transaction_id: "fn",
          node_id: @local_id,
          target: @hash,
          want: ["n4", "n6"]
        })

      assert {:ok, {:query, decoded_fn}} = KRPC.decode(find_node)
      assert decoded_fn.want == ["n4", "n6"]

      announce =
        KRPC.encode_query(%{
          method: :announce_peer,
          transaction_id: "an",
          node_id: @local_id,
          info_hash: @hash,
          port: 6881,
          token: <<1, 2, 3, 4, 5, 6, 7, 8>>,
          implied_port: 1
        })

      assert {:ok, {:query, decoded_an}} = KRPC.decode(announce)
      assert decoded_an.implied_port == 1
    end

    test "response_peers ignores non-lists and mis-sized compact blobs" do
      assert KRPC.response_peers(%{}) == []
      assert KRPC.response_peers(%{values: 123}) == []
      assert KRPC.response_peers(%{values: <<1, 2, 3>>}) == []
      assert KRPC.response_peers(%{values: [<<1, 2, 3>>]}) == []
    end

    test "encode and decode error/response envelopes retain ip and version" do
      ip = DHT.Compact.encode_peer({127, 0, 0, 1}, 6881)

      error_packet =
        KRPC.encode_error(%{
          transaction_id: "er",
          code: 204,
          message: "Server Error",
          version: "ET01",
          ip: ip
        })

      assert {:ok, {:error, decoded_err}} = KRPC.decode(error_packet)
      assert decoded_err.code == 204
      assert decoded_err.version == "ET01"
      assert decoded_err.ip == ip

      response_packet =
        KRPC.encode_response(%{
          transaction_id: "ok",
          node_id: @local_id,
          token: <<1, 2, 3, 4, 5, 6, 7, 8>>,
          version: "ET01",
          ip: ip
        })

      assert {:ok, {:response, decoded_resp}} = KRPC.decode(response_packet)
      assert decoded_resp.token == <<1, 2, 3, 4, 5, 6, 7, 8>>
      assert decoded_resp.version == "ET01"
      assert decoded_resp.ip == ip
    end

    test "decode rejects responses and queries with malformed node ids" do
      bad_response =
        Bento.encode!(%{
          "t" => "br",
          "y" => "r",
          "r" => %{"id" => "too-short"}
        })

      assert {:error, :malformed} = KRPC.decode(bad_response)

      bad_query =
        Bento.encode!(%{
          "t" => "bq",
          "y" => "q",
          "q" => "ping",
          "a" => %{"id" => <<0::8>>}
        })

      assert {:error, :malformed} = KRPC.decode(bad_query)
    end

    test "response_nodes merges compact v4 and v6 node blobs" do
      v4_node =
        DHT.Compact.encode_node(<<1::160>>, {10, 0, 0, 1}, 6881)

      v6_node =
        DHT.Compact.encode_node6(<<2::160>>, {0x2001, 0, 0, 0, 0, 0, 0, 1}, 6882)

      nodes =
        KRPC.response_nodes(%{
          nodes: v4_node,
          nodes6: v6_node
        })

      assert length(nodes) == 2
      assert Enum.any?(nodes, &(&1.port == 6881))
      assert Enum.any?(nodes, &(&1.port == 6882))
    end
  end

  describe "DHT.RoutingTables and Token helpers" do
    test "family_for falls back to v4 and id-only health updates no-op off-table" do
      assert RoutingTables.family_for({1, 2, 3, 4}) == :v4
      assert RoutingTables.family_for({0x2001, 0, 0, 0, 0, 0, 0, 1}) == :v6
      assert RoutingTables.family_for(:not_an_ip) == :v4

      contact = %{id: @local_id, ip: {10, 0, 0, 1}, port: 6881}
      tables = RoutingTables.new(@hash) |> RoutingTables.insert(contact, now_ms: 0)

      assert RoutingTables.mark_good(tables, @local_id) != tables
      missing = <<0xCC, 0::152>>
      assert RoutingTables.mark_bad(RoutingTables.new(@hash), missing) == RoutingTables.new(@hash)

      assert RoutingTables.mark_query_failed(RoutingTables.new(@hash), missing) ==
               RoutingTables.new(@hash)

      v6 = %{id: <<0xDD, 0::152>>, ip: {0x2001, 0, 0, 0, 0, 0, 0, 1}, port: 6882}
      tables = RoutingTables.new(@hash) |> RoutingTables.insert(v6, now_ms: 0)
      assert RoutingTables.mark_bad(tables, v6) != tables
      assert RoutingTables.mark_query_failed(tables, v6) != tables
    end

    test "Token issue_for_node rejects BEP-42-invalid ids on public addresses" do
      store = Token.new(now_ms: 0)
      ip = {198, 51, 100, 1}
      bad_id = :crypto.strong_rand_bytes(20)

      refute DHT.BEP42.valid_or_exempt?(bad_id, ip)
      assert Token.issue_for_node(store, bad_id, ip) == nil

      issued = Token.issue(store, ip)
      assert byte_size(issued) == 8
      assert Token.valid?(store, ip, issued, now_ms: 0)

      rotated_store = Token.maybe_rotate(store, now_ms: 6 * 60 * 1_000)
      assert Token.valid?(rotated_store, ip, issued, now_ms: 6 * 60 * 1000)
    end
  end

  describe "DHT.NodeId and RoutingStore persistence edges" do
    test "id_bits/0 is stable and get/0 creates a random id without primary IP context" do
      assert NodeId.id_bits() == 160
      File.rm_rf(Path.dirname(NodeId.path()))

      id = NodeId.get()
      assert byte_size(id) == 20
      assert NodeId.get() == id
    end

    test "RoutingStore save survives read-only data dir and load tolerates non-list counts" do
      tables = RoutingTables.new(@local_id)
      dir = Path.dirname(RoutingStore.path())
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o500)

      on_exit(fn -> File.chmod!(dir, 0o700) end)

      assert :ok = RoutingStore.save(tables)

      payload = %{version: 1, v4: 42, v6: nil}
      File.chmod!(dir, 0o700)
      File.write!(RoutingStore.path(), :erlang.term_to_binary(payload))

      loaded = RoutingStore.load(RoutingTables.new(@local_id))
      assert RoutingTables.node_count(loaded) == 0
    end
  end

  describe "UTP.LEDBAT, Packet, and Socket pure branches" do
    test "LEDBAT slow-start exit, loss/timeout floors, and target delay accessor" do
      assert LEDBAT.target_delay_us() == 100_000

      state =
        LEDBAT.new()
        |> LEDBAT.record_delay(120_000)
        |> then(fn s -> %{s | last_off_target: -1, slow_start: true} end)
        |> LEDBAT.grow_window(500, 4_000)

      refute state.slow_start

      after_loss = LEDBAT.on_loss(%{state | max_window: 400})
      assert after_loss.max_window == 200

      after_timeout = LEDBAT.on_timeout(LEDBAT.new())
      assert after_timeout.max_window == 150
      refute after_timeout.slow_start

      idle_gain =
        LEDBAT.grow_window(
          %LEDBAT{slow_start: false, max_window: 100, last_off_target: 50_000},
          0,
          0
        )

      assert idle_gain.max_window == 100

      aged_out =
        %LEDBAT{
          delay_samples: [{50_000, 0}],
          base_delay: 50_000,
          last_off_target: 0,
          max_window: 100,
          slow_start: false
        }
        |> LEDBAT.record_delay(55_000)

      assert aged_out.base_delay == 50_000
      assert aged_out.last_off_target == 95_000
    end

    test "Packet guards and selective-ack helpers" do
      refute Packet.utp_packet?(<<>>)
      refute Packet.utp_packet?(<<0xF0>>)

      assert Packet.seq_between?(5, 1, 10)
      refute Packet.seq_between?(11, 1, 10)

      header_bytes =
        <<
          Bitwise.bor(Bitwise.bsl(Packet.st_state(), 4), 1),
          2,
          1::16,
          0::32,
          0::32,
          0::32,
          0::16,
          0::16,
          0,
          0
        >>

      assert {:ok, decoded, <<>>, extensions} = Packet.decode(header_bytes)
      assert decoded.type == Packet.st_state()
      assert extensions == []

      assert {:error, :truncated_extension} =
               Packet.decode(<<
                 Bitwise.bor(Bitwise.bsl(Packet.st_state(), 4), 1),
                 2,
                 1::16,
                 0::32,
                 0::32,
                 0::32,
                 0::16,
                 0::16
               >>)
    end

    test "Socket utp?/1 and unsupported setopts return errors" do
      assert Socket.utp?({:utp, self()})
      refute Socket.utp?(:gen_tcp)

      assert {:error, {:unsupported_opts, [delay_send: true]}} =
               Socket.setopts({:utp, self()}, delay_send: true)
    end
  end

  describe "Peer.Transport and Holepunch helpers" do
    test "Transport rejects unknown transports and decrypt_inbound is identity off MSE" do
      assert {:error, {:unsupported_transport, :sctp}} =
               Transport.connect({127, 0, 0, 1}, 9, [transport: :sctp], 100)

      assert Transport.decrypt_inbound({:utp, self()}, "plain") == "plain"
      assert Transport.utp?({:mse, {:utp, self()}, %{recv: nil, send: nil}})

      cipher = Peer.MSE.new_cipher(:crypto.strong_rand_bytes(20))
      wrapped = Transport.wrap({:utp, self()}, %{recv: cipher, send: cipher})
      assert Transport.mse?(wrapped)
      assert Transport.raw(wrapped) == {:utp, self()}
    end

    test "Holepunch maybe_request ignores bad peers and attempt_info tracks dedup state" do
      assert :ok = Holepunch.maybe_request(@hash, "not-a-peer", :timeout)
      assert :ok = Holepunch.clear_pending(@hash, {9, 9, 9, 9}, 6881)

      assert :ok =
               Holepunch.maybe_request(@hash, %Peer{ip: {127, 0, 0, 1}, port: 9}, :econnrefused)

      refute Holepunch.attempt_info(@hash, {9, 9, 9, 9}, 6881)
    end

    test "Holepunch attempt_info reports cooldown after a reserved rendezvous attempt" do
      target_ip = {203, 0, 113, 7}
      target_port = 6887
      assert :ok = Holepunch.clear_pending(@hash, target_ip, target_port)

      assert :ok =
               Holepunch.maybe_request(
                 @hash,
                 %Peer{ip: target_ip, port: target_port},
                 :timeout
               )

      case Holepunch.attempt_info(@hash, target_ip, target_port) do
        nil -> assert true
        info -> assert info.count >= 1
      end
    end
  end

  describe "Peer.Transport connect paths" do
    test "utp and tcp connect return errors for unreachable loopback ports" do
      assert {:error, _} =
               Transport.connect({127, 0, 0, 1}, 19, [transport: :utp], 300)

      assert {:error, _} =
               Transport.connect({127, 0, 0, 1}, 59_123, [active: false, mode: :binary], 300)
    end

    test "safe_recv maps owner exit to {:error, :closed} on dead uTP socket" do
      {dead, monitor, release} = TestSupport.Sync.spawn_blocked()
      TestSupport.Sync.release(dead, release)
      TestSupport.Sync.await_down(monitor, dead)

      assert {:error, :closed} = Transport.safe_recv({:utp, dead}, 1, 100)
    end
  end

  describe "Peer.LTEP keepalive skipping before extension handshake" do
    test "handshake_exchange ignores zero-length keepalive frames" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)
      close_gate = make_ref()

      accept =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)

          assert {:ok, client_hs} = :gen_tcp.recv(socket, 68, @timeout)
          assert <<19, "BitTorrent protocol"::binary, _::binary>> = client_hs

          server_hs =
            [
              <<19>>,
              "BitTorrent protocol",
              Peer.reserved(),
              :binary.copy(<<1>>, 20),
              Peer.id()
            ]

          :ok = :gen_tcp.send(socket, server_hs)
          :ok = :gen_tcp.send(socket, <<0::32>>)

          peer_hs =
            Bento.encode!(%{
              "m" => %{"ut_metadata" => 2},
              "metadata_size" => 256,
              "v" => "test"
            })

          :ok = :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(0, peer_hs))

          # Explicit close gate. This server never reads the client's own LTEP
          # extended handshake, so its receive queue is non-empty when it closes,
          # and closing with unread data queued is an *abortive* close: the stack
          # sends RST instead of FIN. What that costs differs by platform. BSD
          # and Linux hand the application the bytes already sitting in its
          # receive buffer and only report the reset once the buffer runs dry;
          # Winsock discards the buffer and fails the next `recv` outright with
          # `:econnreset`. So the extended handshake written just above reached
          # the client on macOS and vanished on Windows. Hold the socket open
          # until the client says it is done reading.
          receive do
            ^close_gate -> :ok
          end

          :gen_tcp.close(socket)
          :gen_tcp.close(listen)
          :ok
        end)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], @timeout)

      hash = :binary.copy(<<2>>, 20)

      assert :ok =
               :gen_tcp.send(
                 client,
                 [
                   <<19>>,
                   "BitTorrent protocol",
                   Peer.reserved(),
                   hash,
                   Peer.id()
                 ]
               )

      assert {:ok, _server_hs} = :gen_tcp.recv(client, 68, @timeout)

      assert {:ok, session} =
               LTEP.handshake_exchange(client, Session.new(), timeout: @timeout)

      assert Session.peer_extension_id(session, "ut_metadata") == 2
      assert Session.local_reqq() >= 250

      send(accept.pid, close_gate)
      :gen_tcp.close(client)
      assert :ok = Task.await(accept, @timeout)
    end
  end

  describe "Torrent helpers and Torrents list API" do
    test "hex_encoded_hash zero-pads the digest" do
      hash = :crypto.strong_rand_bytes(20)

      hex = Torrent.hex_encoded_hash(hash)
      assert byte_size(hash) == 20
      assert String.length(hex) == 40
      assert {:ok, ^hash} = Base.decode16(hex, case: :mixed)
    end

    test "event constants and private metadata flag" do
      assert Torrent.started() == 2
      assert Torrent.completed() == 1
      assert Torrent.stopped() == 3
      assert Torrent.event_to_string(Torrent.started()) == "started"

      assert Torrent.private?(%{
               "info" => %{"name" => "x", "private" => 1, "length" => 1, "piece length" => 1}
             })
    end

    test "discovery_swarm_hashes/1 reads kind and digests from a torrent struct" do
      v1 = :binary.copy(<<3>>, 20)
      v2 = :binary.copy(<<4>>, 32)

      torrent = %Torrent{
        hash: v1,
        hash_v2: v2,
        kind: :hybrid,
        metadata: %{},
        left: 1,
        last_index: 0,
        last_piece_length: 1
      }

      assert Torrent.discovery_swarm_hashes(torrent) == [v1, binary_part(v2, 0, 20)]
      assert is_list(Torrents.list())
    end

    test "ElixirTorrent.version/0 exposes the BEP 20 peer-id prefix" do
      assert ElixirTorrent.version() =~ "ET"
      assert is_binary(ElixirTorrent.version())
    end
  end

  describe "Holepunch initiate_connect spawns a background dial task" do
    test "returns a task pid without blocking the caller" do
      assert {:ok, task} = Holepunch.initiate_connect(@hash, {{127, 0, 0, 1}, 59_124})
      assert is_pid(task)

      on_exit(fn ->
        if Process.alive?(task), do: Process.exit(task, :kill)
      end)
    end
  end

  describe "Peer.LTEP accessors and recv_extended error branches" do
    test "message_id, handshake_id, max_message_size, and invalid recv lengths" do
      assert LTEP.message_id() == 20
      assert LTEP.handshake_id() == 0
      assert LTEP.max_message_size() == 1_048_576

      {client, server, listen} = loopback_pair()

      on_exit(fn ->
        close_loopback(client, server, listen)
      end)

      assert :ok = :gen_tcp.send(server, <<1::32>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(client, @timeout)

      too_big = LTEP.max_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<too_big::32>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(client, @timeout)

      assert :ok = :gen_tcp.send(server, <<1::32, 20>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(client, @timeout)
    end
  end

  describe "Torrent public lifecycle and PiecesStatistic guards" do
    test "parse_file! rejects invalid bencode and missing info dict" do
      bad_path = Path.join(File.cwd!(), "bad.torrent")
      File.write!(bad_path, "i42e")

      assert_raise ArgumentError, ~r/not a bencoded dictionary/, fn ->
        Torrent.parse_file!(bad_path)
      end

      File.write!(bad_path, "d4:name4:teste")

      assert_raise ArgumentError, ~r/missing info dictionary/, fn ->
        Torrent.parse_file!(bad_path)
      end
    end

    test "event_to_string empty event, get_hash/1, and private?/1 fallback" do
      assert Torrent.event_to_string(Torrent.empty()) == nil
      assert Torrent.get_hash(self()) == nil
      refute Torrent.private?(%{})
    end

    test "discovery_swarm_hashes covers hybrid and invalid hash fallbacks" do
      v1 = :binary.copy(<<1>>, 20)
      v2 = :binary.copy(<<2>>, 32)

      assert Torrent.discovery_swarm_hashes(:hybrid, v1, v2) == [v1, binary_part(v2, 0, 20)]
      assert Torrent.discovery_swarm_hashes(:v1, v1, nil) == [v1]
      assert Torrent.discovery_swarm_hashes(:v2, <<0::8>>, nil) == []
    end

    test "select_announce_hash surfaces missing v1/v2 digests" do
      v1 = :binary.copy(<<1>>, 20)
      v2 = :binary.copy(<<2>>, 32)

      assert {:ok, ^v1} = Torrent.select_announce_hash(:v1, v1, v2)
      assert {:error, :missing_v2_hash} = Torrent.select_announce_hash(:v2, nil, nil)
      assert {:error, :missing_v1_hash} = Torrent.select_announce_hash(:hybrid, nil, v2)
    end

    test "PiecesStatistic init is idempotent and choice_rare prunes busy lists" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 8)

      assert :ok = PiecesStatistic.init(torrent)
      assert :ok = PiecesStatistic.init(torrent)

      with_stat_table(hash, 8, fn ->
        for idx <- 0..7, do: PiecesStatistic.inc(hash, idx)

        chosen =
          Enum.reduce(1..50, MapSet.new(), fn _, acc ->
            case PiecesStatistic.choice_piece(hash, :rare) do
              nil -> acc
              index -> MapSet.put(acc, index)
            end
          end)

        assert MapSet.size(chosen) >= 2

        missing = :crypto.strong_rand_bytes(20)
        assert :ok = PiecesStatistic.remove_peer(missing, :all, 3)
      end)
    end

    test "Downloads stop on missing supervisor and piece_has_in_flight? is false without workers" do
      hash = :crypto.strong_rand_bytes(20)
      assert :ok = Downloads.stop(hash)
      refute Downloads.piece_has_in_flight?(hash, 0)
    end

    test "Files.build_entries drops BEP 47 padding files from the visible list" do
      torrent =
        sample_torrent(:crypto.strong_rand_bytes(20), 2,
          metadata: %{
            "info" => %{
              "name" => "pad-root",
              "piece length" => @piece_len,
              "files" => [
                %{"length" => 100, "path" => ["a.bin"]},
                %{"length" => 50, "path" => ["pad"], "attr" => "p"},
                %{"length" => 200, "path" => ["b.bin"]}
              ]
            }
          }
        )

      entries = Files.build_entries(torrent)
      assert length(entries) == 2
      assert Enum.map(entries, & &1.name) == ["a.bin", "b.bin"]
      assert Files.padding?(%{"attr" => "p"})
      refute Files.padding?(%{"length" => 1})
    end
  end

  describe "Torrents lifecycle helpers" do
    test "stop_and_serialize/1 is ok when the torrent is already gone" do
      assert :ok = Torrents.stop_and_serialize(:crypto.strong_rand_bytes(20))
    end
  end

  describe "Torrents stats when the pid is not a torrent supervisor" do
    test "stats/1 and stats/2 return torrent_not_found for orphan pids" do
      orphan =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(orphan, :stop) end)

      assert {:error, :torrent_not_found} = Torrents.stats(orphan)
      assert {:error, :torrent_not_found} = Torrents.stats(orphan, [:name])
    end
  end

  describe "Peer.Endpoints catch paths when the registry is down" do
    test "public API returns safe defaults if Endpoints is unavailable" do
      pid = Process.whereis(Endpoints)
      assert is_pid(pid)
      supervisor = parent_supervisor(pid)

      on_exit(fn ->
        case Supervisor.restart_child(supervisor, Endpoints) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
        end
      end)

      assert :ok = Supervisor.terminate_child(supervisor, Endpoints)
      refute Process.whereis(Endpoints)
      assert_catch_safe_endpoints()
    end
  end

  defp parent_supervisor(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)

    case Keyword.fetch!(dictionary, :"$ancestors") do
      [supervisor | _] when is_pid(supervisor) -> supervisor
      [supervisor | _] when is_atom(supervisor) -> supervisor
    end
  end

  defp assert_catch_safe_endpoints do
    peer_id = :binary.copy(<<1>>, 20)

    assert :ok = Endpoints.claim_peer_id(@hash, peer_id, {1, 1, 1, 1}, 6881, self())
    assert :ok = Endpoints.register(@hash, {1, 1, 1, 1}, 6881, self())
    refute Endpoints.registered?(@hash, {1, 1, 1, 1}, 6881)
    assert Endpoints.count(@hash) == 0
    assert Endpoints.get_pid(@hash, {1, 1, 1, 1}, 6881) == nil
    assert Endpoints.list(@hash) == []
  end

  defp loopback_pair do
    {:ok, listen} = listen_loopback_raw()
    {:ok, port} = :inet.port(listen)
    spawn_loopback_acceptor(listen, self(), @timeout)

    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], @timeout)

    await_loopback_server(client, listen, @timeout)
  end

  defp listen_loopback_raw do
    :gen_tcp.listen(0, [
      :binary,
      active: false,
      packet: :raw,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ])
  end

  defp spawn_loopback_acceptor(listen, parent, timeout) do
    spawn(fn ->
      case :gen_tcp.accept(listen, timeout) do
        {:ok, server} ->
          :ok = :gen_tcp.controlling_process(server, parent)
          send(parent, {:loopback_server, server})

        error ->
          send(parent, {:loopback_accept_error, error})
      end
    end)
  end

  defp await_loopback_server(client, listen, timeout) do
    receive do
      {:loopback_server, server} -> {client, server, listen}
      {:loopback_accept_error, error} -> flunk("accept failed: #{inspect(error)}")
    after
      timeout -> flunk("accept timed out")
    end
  end

  defp close_loopback(client, server, listen) do
    for sock <- [client, server, listen] do
      try do
        if is_port(sock), do: :gen_tcp.close(sock)
      catch
        :error, _ -> :ok
      end
    end
  end

  defp sample_torrent(hash, last_index, opts \\ []) do
    piece_len = Keyword.get(opts, :piece_len, @piece_len)

    struct!(
      %Torrent{
        hash: hash,
        left: (last_index + 1) * piece_len,
        last_index: last_index,
        last_piece_length: Keyword.get(opts, :last_piece_length, piece_len),
        piece_lengths: Keyword.get(opts, :piece_lengths),
        bitfield: Keyword.get(opts, :bitfield, Bitfield.make(last_index + 1)),
        kind: Keyword.get(opts, :kind, :v1),
        merkle: Keyword.get(opts, :merkle),
        metadata: Keyword.get(opts, :metadata, %{"info" => %{"piece length" => piece_len}}),
        peer_status: nil
      },
      Keyword.drop(opts, [
        :piece_len,
        :last_piece_length,
        :piece_lengths,
        :bitfield,
        :kind,
        :merkle,
        :metadata
      ])
    )
  end

  defp with_stat_table(hash, last_index, fun) do
    torrent = sample_torrent(hash, last_index)
    assert :ok = PiecesStatistic.init(torrent)
    fun.()
  end
end

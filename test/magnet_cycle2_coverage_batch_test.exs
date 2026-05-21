defmodule Magnet.Cycle2CoverageBatchTest do
  use ExUnit.Case, async: false

  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias Peer.LTEP.{Handshake, Session}
  @timeout 2_000
  @recv_fast_ms 200
  @piece_len 16_384
  @peer_ut_id 5
  @swarm_peer_ut_id 2
  @local_ut_id UtMetadataExtension.local_id()
  @interested_id Peer.Const.interested_id()

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)

    previous_connection = Application.get_env(:elixir_torrent, :magnet_connection, [])
    previous_connected = Application.get_env(:elixir_torrent, :magnet_connected_metadata, [])
    previous_fetcher = Application.get_env(:elixir_torrent, :magnet_fetcher, [])
    previous_dht = Application.get_env(:elixir_torrent, :dht, [])
    previous_handler = Application.get_env(:elixir_torrent, :metadata_ok_handler)

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :magnet_connection, previous_connection)
      Application.put_env(:elixir_torrent, :magnet_connected_metadata, previous_connected)
      Application.put_env(:elixir_torrent, :magnet_fetcher, previous_fetcher)
      Application.put_env(:elixir_torrent, :dht, previous_dht)
      Application.put_env(:elixir_torrent, :metadata_ok_handler, previous_handler)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)
    short_connection_env!()
    short_connected_env!()
    :ok
  end

  describe "UtMetadata decode and verify edge branches" do
    test "parse_extension_handshake accepts Handshake struct" do
      hs = %Handshake{m: %{"ut_metadata" => 3}, metadata_size: 512}

      assert %{ut_metadata_id: 3, metadata_size: 512} =
               Magnet.UtMetadata.parse_extension_handshake(hs)
    end

    test "decode_message rejects trailing bytes on request and reject messages" do
      request = Magnet.UtMetadata.encode_request(0) <> <<0xFF>>
      reject = Magnet.UtMetadata.encode_reject(0) <> <<0xFF>>

      assert {:error, :trailing_data} = Magnet.UtMetadata.decode_message(request)
      assert {:error, :trailing_data} = Magnet.UtMetadata.decode_message(reject)
    end

    test "decode_message rejects data without total_size and oversized piece bodies" do
      bad_data = Bento.encode!(%{"msg_type" => 1, "piece" => 0}) <> <<0>>
      huge = Bento.encode!(%{"msg_type" => 1, "piece" => 0, "total_size" => 100})
      huge = huge <> :binary.copy(<<0>>, Magnet.UtMetadata.block_size() + 1)

      assert {:error, :missing_total_size} = Magnet.UtMetadata.decode_message(bad_data)
      assert {:error, :piece_too_large} = Magnet.UtMetadata.decode_message(huge)
    end

    test "decode_message rejects unknown msg_type fields" do
      assert {:error, :invalid_message_fields} =
               Magnet.UtMetadata.decode_message(Bento.encode!(%{"msg_type" => 9, "piece" => 0}))
    end

    test "split_bencoded_prefix distinguishes dictionary vs list and invalid bencode" do
      assert {:error, :expected_dictionary} =
               Magnet.UtMetadata.split_bencoded_prefix(Bento.encode!([]))

      assert {:error, :invalid_bencode} = Magnet.UtMetadata.split_bencoded_prefix("i-0e")
      assert {:error, :invalid_bencode} = Magnet.UtMetadata.split_bencoded_prefix("i-00e")
    end

    test "piece_count and piece_byte_size cover final partial block math" do
      total = @piece_len + 500
      assert Magnet.UtMetadata.piece_count(total) == 2
      assert Magnet.UtMetadata.piece_byte_size(total, 0) == @piece_len
      assert Magnet.UtMetadata.piece_byte_size(total, 1) == 500
    end

    test "assemble_pieces and decode_and_verify_info surface incomplete, size, and invalid info" do
      total = 100

      assert {:error, :incomplete} =
               Magnet.UtMetadata.assemble_pieces(%{0 => :binary.copy(<<0>>, 50)}, total)

      wrong_hash = :crypto.strong_rand_bytes(20)
      good_blob = Bento.encode!(%{"name" => "x", "length" => 1})

      assert {:error, :info_hash_mismatch} =
               Magnet.UtMetadata.decode_and_verify_info(good_blob, wrong_hash)

      blob = Bento.encode!("not-a-map")
      hash = :crypto.hash(:sha, blob)

      assert {:error, :invalid_info} = Magnet.UtMetadata.decode_and_verify_info(blob, hash)
    end
  end

  describe "Fetcher.on_metadata_ok/2 upgrade/announce/discovery" do
    test "on_metadata_ok stops bootstrap, seeds x.pe, and invokes metadata_ok_handler" do
      hash = <<50::160>>

      magnet = %Magnet{
        hash: hash,
        trackers: ["http://tracker.example/ann"],
        x_pe_peers: [%Peer{ip: {9, 9, 9, 9}, port: 9999}],
        display_name: "ok-handler"
      }

      test_pid = self()

      Application.put_env(:elixir_torrent, :metadata_ok_handler, fn mag, path ->
        send(test_pid, {:metadata_ok_handler, mag.hash, path})
        :ok
      end)

      :ok = Magnet.Bootstrap.ensure(magnet)
      assert Magnet.Bootstrap.active?(hash)

      path = Magnet.Fetcher.torrent_path(hash)
      on_exit(fn -> File.rm(path) end)

      assert :ok = Magnet.Fetcher.on_metadata_ok(magnet, path)
      refute Magnet.Bootstrap.active?(hash)
      assert PeerDiscovery.SeedPeers.take(hash) == magnet.x_pe_peers
      assert_receive {:metadata_ok_handler, ^hash, ^path}, @timeout
    end

    test "on_metadata_ok is a no-op when metadata_ok_handler is unset" do
      hash = <<51::160>>
      magnet = %Magnet{hash: hash, trackers: [], x_pe_peers: [], display_name: nil}
      path = Magnet.Fetcher.torrent_path(hash)

      Application.put_env(:elixir_torrent, :metadata_ok_handler, nil)
      assert :ok = Magnet.Fetcher.on_metadata_ok(magnet, path)
    end

    test "upgrade_magnet delivers upgrade message to an active fetch session" do
      hash = <<52::160>>
      parent = self()

      holder =
        spawn(fn ->
          assert {:ok, _} = Registry.register(Registry, {:magnet_fetch, hash}, make_ref())
          send(parent, {:holder_ready, self()})

          receive do
            {:upgrade_magnet, %Magnet{} = mag} ->
              send(parent, {:upgraded, mag.display_name})

            :stop ->
              Registry.unregister(Registry, {:magnet_fetch, hash})
          end
        end)

      on_exit(fn -> send(holder, :stop) end)
      assert_receive {:holder_ready, ^holder}, @timeout

      incoming = %Magnet{
        hash: hash,
        trackers: ["http://127.0.0.1:1/announce"],
        x_pe_peers: [],
        display_name: "cycle2-upgrade"
      }

      assert :ok = Magnet.Fetcher.upgrade_magnet(hash, incoming)
      assert_receive {:upgraded, "cycle2-upgrade"}, @timeout
    end

    test "announce_stopped posts stopped event to loopback HTTP tracker" do
      hash = :crypto.strong_rand_bytes(20)
      test_pid = self()
      body = Bento.encode!(%{"interval" => 60, "peers" => <<>>})

      {port, server_ref} =
        start_http_tracker(fn request ->
          send(test_pid, {:stopped_request, request})
          {200, body}
        end)

      on_exit(fn -> Process.exit(server_ref, :kill) end)

      assert :ok =
               Magnet.Fetcher.announce_stopped(hash, ["http://127.0.0.1:#{port}/announce"])

      assert_receive {:stopped_request, request}, @timeout
      assert request =~ "event=stopped"
    end

    test "discover_and_merge_peers collects loopback tracker peers when DHT is disabled" do
      hash = <<53::160>>
      peers_bin = <<127, 0, 0, 1, 6881::16>>

      body =
        Bento.encode!(%{
          "interval" => 120,
          "complete" => 0,
          "incomplete" => 1,
          "peers" => peers_bin
        })

      {port, server_ref} = start_http_tracker(fn _req -> {200, body} end)
      on_exit(fn -> Process.exit(server_ref, :kill) end)

      magnet = %Magnet{
        hash: hash,
        trackers: ["http://127.0.0.1:#{port}/announce"],
        x_pe_peers: [],
        display_name: nil
      }

      {merged, peers_new, trackers} =
        Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})

      assert peers_new == 1
      assert map_size(merged) == 1
      assert trackers == ["http://127.0.0.1:#{port}/announce"]
      assert [%Peer{ip: {127, 0, 0, 1}, port: 6881}] = Map.values(merged)
    end

    test "discover_and_merge_peers ignores tracker failure responses" do
      hash = <<54::160>>
      failure = Bento.encode!(%{"failure reason" => "unregistered torrent"})

      {port, server_ref} = start_http_tracker(fn _req -> {200, failure} end)
      on_exit(fn -> Process.exit(server_ref, :kill) end)

      magnet = %Magnet{
        hash: hash,
        trackers: ["http://127.0.0.1:#{port}/announce"],
        x_pe_peers: [],
        display_name: nil
      }

      {merged, peers_new, _} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
      assert merged == %{}
      assert peers_new == 0
    end

    test "fetch_metadata_from_peer_for_test fetches multi-piece metadata over direct TCP" do
      pad = 18_000

      info = %{
        "name" => "cycle2-multi",
        "length" => pad + 64,
        "piece length" => @piece_len,
        "pieces" => :binary.copy(<<0::160>>, 2),
        "pad" => :binary.copy(<<0xCD>>, pad)
      }

      info_blob = Bento.encode!(info)
      hash = :crypto.hash(:sha, info_blob)
      assert Magnet.UtMetadata.piece_count(byte_size(info_blob)) == 2

      magnet = %Magnet{hash: hash, trackers: [], display_name: "multi"}
      path = Magnet.Fetcher.torrent_path(hash)
      on_exit(fn -> File.rm(path) end)

      {port, _} = start_handshake_server!(hash, info_blob, mode: :serve)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:ok, ^path, false} =
               Magnet.Fetcher.fetch_metadata_from_peer_for_test(magnet, peer, [peer])

      assert File.read!(path) == Magnet.build_torrent!(magnet, info_blob)
    end

    test "download_pieces returns metadata_unavailable when every peer rejects" do
      hash = :crypto.strong_rand_bytes(20)

      info = %{
        "name" => "1234567890",
        "length" => 64,
        "piece length" => @piece_len,
        "pieces" => <<0::160>>
      }

      info_blob = Bento.encode!(info)
      {port, _} = start_handshake_server!(hash, info_blob, mode: :reject)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:ok, conn} = Magnet.Connection.open(peer, hash)

      try do
        assert {:error, :metadata_unavailable} = Magnet.Fetcher.download_pieces([conn], hash)
      after
        Magnet.Connection.close(conn)
      end
    end

    test "announce_stopped tolerates tracker HTTP failures" do
      hash = :crypto.strong_rand_bytes(20)

      {port, server_ref} =
        start_http_tracker(fn _req ->
          throw(:simulate_crash)
        end)

      on_exit(fn -> Process.exit(server_ref, :kill) end)

      assert :ok =
               Magnet.Fetcher.announce_stopped(hash, ["http://127.0.0.1:#{port}/announce"])
    end

    test "discover_and_merge_peers fans out across many loopback trackers" do
      hash = <<55::160>>
      peers_bin = <<127, 0, 0, 1, 6881::16, 127, 0, 0, 1, 6882::16>>

      body =
        Bento.encode!(%{
          "interval" => 60,
          "peers" => peers_bin
        })

      trackers =
        for idx <- 1..10 do
          {port, server_ref} = start_http_tracker(fn _req -> {200, body} end)
          on_exit(fn -> Process.exit(server_ref, :kill) end)
          "http://127.0.0.1:#{port}/announce?idx=#{idx}"
        end

      magnet = %Magnet{hash: hash, trackers: trackers, x_pe_peers: [], display_name: nil}

      {merged, peers_new, announced} = Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{})
      assert peers_new >= 1
      assert map_size(merged) >= 1
      assert length(announced) == 10
    end
  end

  describe "Fetcher.fetch_metadata_round/3 swarm/direct aggregation" do
    test "returns swarm success without direct TCP when swarm serves metadata" do
      {info_map, info_blob, hash} = build_info_blob!(name: "round-swarm-ok")
      metadata_size = byte_size(info_blob)
      magnet = %Magnet{hash: hash, trackers: ["http://loopback/ann"], display_name: "swarm-ok"}
      path = Magnet.Fetcher.torrent_path(hash)
      on_exit(fn -> File.rm(path) end)

      with_metadata_peer(hash, info_blob, metadata_size, fn _key, _ref ->
        dummy = %Peer{ip: {127, 0, 0, 1}, port: 1}

        assert {:ok, ^path, trackers, false} =
                 Magnet.Fetcher.fetch_metadata_round(magnet, [dummy], ["http://loopback/ann"])

        assert trackers == ["http://loopback/ann"]
        assert File.read!(path) == Magnet.build_torrent!(magnet, info_blob)
        assert info_map["name"] == "round-swarm-ok"
        refute Magnet.Bootstrap.active?(hash)
      end)
    end

    test "merges swarm failure list when direct TCP also returns metadata_unavailable" do
      {_, info_blob, hash} = build_info_blob!(name: "round-merge-list")
      metadata_size = byte_size(info_blob)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "merge-list"}

      {port, _listen_ref} = start_handshake_server!(hash, info_blob, mode: :reject)
      direct_peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      with_metadata_peers(
        hash,
        [
          {<<20::160>>, {:metadata, info_blob, metadata_size, mode: :silent}},
          {<<21::160>>, {:metadata, info_blob, metadata_size, mode: :reject}}
        ],
        fn _keys, _refs ->
          Application.put_env(
            :elixir_torrent,
            :magnet_connection,
            Keyword.put(
              Application.get_env(:elixir_torrent, :magnet_connection, []),
              :recv_timeout_ms,
              @recv_fast_ms
            )
          )

          assert {:error, {:metadata_unavailable, failures}} =
                   Magnet.Fetcher.fetch_metadata_round(magnet, [direct_peer], [])

          assert :timeout in failures
          assert :metadata_rejected in failures or :metadata_unavailable in failures
        end
      )
    end

    test "propagates info_hash_mismatch from direct path after swarm is empty" do
      {info_map, info_blob, hash} = build_info_blob!(name: "1234567890")
      wrong_blob = Bento.encode!(Map.put(info_map, "name", "0987654321"))
      assert byte_size(wrong_blob) == byte_size(info_blob)

      {port, _listen_ref} = start_handshake_server!(hash, wrong_blob, mode: :serve)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      magnet = %Magnet{hash: hash, trackers: [], display_name: "mismatch"}

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      Application.put_env(
        :elixir_torrent,
        :magnet_connected_metadata,
        wait_for_peers_ms: 1,
        wait_poll_ms: 1,
        wait_max_ms: 1,
        min_peers_gather_ms: 1,
        min_peers_for_round: 4
      )

      assert {:error, :info_hash_mismatch} =
               Magnet.Fetcher.fetch_metadata_round(magnet, [peer], [])
    end

    test "returns info_hash_mismatch from swarm without attempting direct when wire hash fails" do
      {info_map, info_blob, hash} = build_info_blob!(name: "1234567890")
      wrong_blob = Bento.encode!(Map.put(info_map, "name", "0987654321"))
      assert byte_size(wrong_blob) == byte_size(info_blob)
      metadata_size = byte_size(wrong_blob)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "swarm-mismatch"}

      with_metadata_peer(hash, wrong_blob, metadata_size, fn _key, _ref ->
        dummy = %Peer{ip: {127, 0, 0, 1}, port: 9}

        assert {:error, :info_hash_mismatch} =
                 Magnet.Fetcher.fetch_metadata_round(magnet, [dummy], [])
      end)
    end
  end

  describe "Connection wire and open branches" do
    test "open rejects peers without BEP 10 extension protocol bit" do
      hash = :crypto.strong_rand_bytes(20)
      {port, _listen_ref} = start_plain_handshake_server!(hash, extension?: false)

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      assert {:error, :no_extension_protocol} = Magnet.Connection.open(peer, hash)
    end

    test "open rejects handshake info-hash mismatch" do
      hash = :crypto.strong_rand_bytes(20)
      other = :crypto.strong_rand_bytes(20)
      {port, _listen_ref} = start_plain_handshake_server!(other, extension?: true)

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      assert {:error, :info_hash_mismatch} = Magnet.Connection.open(peer, hash)
    end

    test "fetch_metadata learns total_size from piece zero when metadata_size is absent" do
      info = %{
        "name" => "1234567890",
        "length" => 64,
        "piece length" => @piece_len,
        "pieces" => <<0::160>>
      }

      info_blob = Bento.encode!(info)
      hash = :crypto.hash(:sha, info_blob)

      {port, _listen_ref} =
        start_handshake_server!(hash, info_blob, mode: :serve, advertise_metadata_size?: false)

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:ok, decoded, blob} = Magnet.Connection.fetch_metadata(peer, hash)
      assert decoded["name"] == "1234567890"
      assert :crypto.hash(:sha, blob) == hash
    end

    test "request_piece ignores malformed extended payload then accepts valid data" do
      total_size = 100
      data = :binary.copy(<<0xAB>>, total_size)

      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, _payload} = recv_extended_request(server)

        :ok =
          :gen_tcp.send(
            server,
            Peer.LTEP.extended_message_wire(99, "not-a-bencode-dict")
          )

        send_ut_data(server, 0, total_size, data)
        :gen_tcp.close(server)
      end)

      conn = ut_metadata_conn(client, total_size: total_size, unchoked?: true)
      assert {:ok, ^data, ^total_size} = Magnet.Connection.request_piece(conn, 0)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "request_piece returns no_ut_metadata when peer never negotiated ut_metadata id" do
      {client, _server, listen} = loopback_pair!()

      ltep = Session.new([])

      conn = %Magnet.Connection{
        socket: client,
        ltep: ltep,
        metadata_size: 64,
        transport: :tcp,
        unchoked?: true
      }

      assert {:error, :no_ut_metadata} = Magnet.Connection.request_piece(conn, 0)
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "open returns no_ut_metadata when peer LTEP omits ut_metadata" do
      hash = :crypto.strong_rand_bytes(20)

      {port, _listen_ref} =
        start_handshake_server!(hash, Bento.encode!(%{"name" => "x"}),
          mode: :serve,
          ltep: :no_ut_metadata
        )

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      assert {:error, :no_ut_metadata} = Magnet.Connection.open(peer, hash)
    end

    test "open returns invalid_handshake for truncated peer handshake" do
      hash = :crypto.strong_rand_bytes(20)
      parent = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)

      spawn(fn ->
        send(parent, {:trunc_listen, listen})

        case :gen_tcp.accept(listen, @timeout) do
          {:ok, socket} ->
            _ = :gen_tcp.recv(socket, 68, @timeout)
            :gen_tcp.send(socket, <<0::80>>)
            :gen_tcp.close(socket)

          _ ->
            :ok
        end

        :gen_tcp.close(listen)
      end)

      assert_receive {:trunc_listen, ^listen}, @timeout
      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:error, reason} = Magnet.Connection.open(peer, hash)
      assert reason in [:invalid_handshake, :closed]
    end

    test "request_piece ignores wrong-piece reject then accepts matching data" do
      total_size = 100
      data = :binary.copy(<<0xEE>>, total_size)

      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, _payload} = recv_extended_request(server)
        send_ut_reject(server, 1)
        send_ut_data(server, 0, total_size, data)
        :gen_tcp.close(server)
      end)

      conn = ut_metadata_conn(client, total_size: total_size, unchoked?: true)
      assert {:ok, ^data, ^total_size} = Magnet.Connection.request_piece(conn, 0)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "fetch_metadata downloads multi-piece blob over direct TCP" do
      pad = 18_000

      info = %{
        "name" => "1234567890",
        "length" => pad + 50,
        "piece length" => @piece_len,
        "pieces" => :binary.copy(<<0::160>>, 2),
        "pad" => :binary.copy(<<0>>, pad)
      }

      info_blob = Bento.encode!(info)
      hash = :crypto.hash(:sha, info_blob)
      assert byte_size(info_blob) > @piece_len

      {port, _} = start_handshake_server!(hash, info_blob, mode: :serve)
      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      assert {:ok, _decoded, ^info_blob} = Magnet.Connection.fetch_metadata(peer, hash)
    end

    test "open_swarm times out controller_ready when ut_metadata never appears" do
      hash = :crypto.strong_rand_bytes(20)

      Application.put_env(:elixir_torrent, :magnet_connection,
        unchoke_wait_ms: 1,
        controller_unchoke_poll_ms: 1
      )

      with_open_swarm_stack(hash, fn key, _server ->
        bare_ltep = Session.new([])

        replace_controller_state(key, fn state ->
          %{state | ltep: bare_ltep, bitfield: nil, choke_me: false}
        end)

        info = %{ltep: bare_ltep, metadata_size: nil, unchoked?: true, seeder?: false}

        assert {:error, :metadata_unavailable} = Magnet.Connection.open_swarm(key, info)
        assert sender_active?(key)
      end)
    end
  end

  describe "ConnectedMetadata wait-ready and failure normalization" do
    test "fetch proceeds with one metadata peer when gather deadline passes below min_peers_for_round" do
      {_, info_blob, hash} = build_info_blob!(name: "partial-gather", private: true)
      metadata_size = byte_size(info_blob)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "partial-gather"}
      path = Magnet.Fetcher.torrent_path(hash)
      on_exit(fn -> File.rm(path) end)

      Application.put_env(:elixir_torrent, :magnet_connected_metadata,
        wait_for_peers_ms: 500,
        wait_poll_ms: 1,
        wait_max_ms: 500,
        min_peers_gather_ms: 1,
        min_peers_for_round: 4
      )

      with_metadata_peer(hash, info_blob, metadata_size, fn _key, _ref ->
        assert {:ok, ^path, [], true} = Magnet.ConnectedMetadata.fetch(magnet, [])
        assert File.read!(path) == Magnet.build_torrent!(magnet, info_blob)
      end)
    end
  end

  describe "Bootstrap lifecycle" do
    test "ensure active stop and offer_peers integrate with bootstrap swarm" do
      hash = <<60::160>>

      magnet = %Magnet{
        hash: hash,
        trackers: ["http://example.invalid/announce"],
        x_pe_peers: [],
        display_name: "bootstrap-cycle2"
      }

      refute Magnet.Bootstrap.active?(hash)
      assert :ok = Magnet.Bootstrap.ensure(magnet)
      assert Magnet.Bootstrap.active?(hash)

      offered = [%Peer{ip: {1, 2, 3, 4}, port: 6881}]
      assert :ok = Magnet.Bootstrap.offer_peers(hash, offered)
      assert :ok = Magnet.Bootstrap.stop(hash)
      refute Magnet.Bootstrap.active?(hash)
      assert :ok = Magnet.Bootstrap.stop(hash)
    end
  end

  ## shared helpers ----------------------------------------------------------

  defp short_connection_env!(overrides \\ []) do
    defaults = [unchoke_wait_ms: 50, unchoke_stable_ms: 0, recv_timeout_ms: @timeout]

    Application.put_env(
      :elixir_torrent,
      :magnet_connection,
      Keyword.merge(defaults, overrides)
    )
  end

  defp short_connected_env!(overrides \\ []) do
    defaults = [
      wait_for_peers_ms: 50,
      wait_poll_ms: 1,
      wait_max_ms: 50,
      min_peers_gather_ms: 1,
      min_peers_for_round: 1,
      max_peers: 4,
      metadata_parallel: 4,
      peer_timeout_ms: 5_000,
      ltep_metadata_wait_ms: 50
    ]

    Application.put_env(
      :elixir_torrent,
      :magnet_connected_metadata,
      Keyword.merge(defaults, overrides)
    )
  end

  defp build_info_blob!(opts) do
    info = %{
      "name" => Keyword.fetch!(opts, :name),
      "length" => Keyword.get(opts, :length, 128),
      "piece length" => @piece_len,
      "pieces" => <<0::160>>
    }

    info =
      if Keyword.get(opts, :private, false),
        do: Map.put(info, "private", 1),
        else: info

    blob = Bento.encode!(info)
    {info, blob, :crypto.hash(:sha, blob)}
  end

  defp loopback_pair! do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    {:ok, client} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])

    {:ok, server} = :gen_tcp.accept(listen, @timeout)
    {client, server, listen}
  end

  defp ut_metadata_conn(client, opts) do
    total_size = Keyword.fetch!(opts, :total_size)
    unchoked? = Keyword.get(opts, :unchoked?, true)

    peer_hs = %Handshake{m: %{"ut_metadata" => @peer_ut_id}, metadata_size: total_size}

    ltep =
      Session.new([UtMetadataExtension])
      |> Session.apply_peer_handshake(peer_hs)

    %Magnet.Connection{
      socket: client,
      ltep: ltep,
      metadata_size: total_size,
      transport: :tcp,
      unchoked?: unchoked?,
      unchoke_since: if(unchoked?, do: System.monotonic_time(:millisecond) - 1_000, else: nil)
    }
  end

  defp recv_extended_request(socket) do
    {:ok, <<len::32>>} = :gen_tcp.recv(socket, 4, @timeout)
    {:ok, <<20, @peer_ut_id, payload::binary>>} = :gen_tcp.recv(socket, len, @timeout)
    {:ok, payload}
  end

  defp send_ut_data(socket, piece, total_size, data) do
    wire =
      Peer.LTEP.extended_message_wire(
        @local_ut_id,
        Magnet.UtMetadata.encode_data(piece, total_size, data)
      )

    :gen_tcp.send(socket, wire)
  end

  defp send_ut_reject(socket, piece) do
    wire =
      Peer.LTEP.extended_message_wire(
        @local_ut_id,
        Magnet.UtMetadata.encode_reject(piece)
      )

    :gen_tcp.send(socket, wire)
  end

  defp start_http_tracker(responder) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn(fn ->
        serve_http(listen, responder)
      end)

    {port, pid}
  end

  defp serve_http(listen, responder) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> handle_http_client(socket, responder) end)
        serve_http(listen, responder)

      {:error, _} ->
        :ok
    end
  end

  defp handle_http_client(socket, responder) do
    case :gen_tcp.recv(socket, 0, @timeout) do
      {:ok, request} ->
        {code, body} =
          case responder.(request) do
            {c, b} -> {c, b}
            {c, b, _h} -> {c, b}
          end

        status = if code == 200, do: "200 OK", else: "#{code} Error"

        response =
          [
            "HTTP/1.1 #{status}\r\n",
            "Content-Length: #{byte_size(body)}\r\n",
            "Connection: close\r\n\r\n",
            body
          ]

        :gen_tcp.send(socket, response)

      _ ->
        :ok
    end
  after
    :gen_tcp.close(socket)
  end

  defp start_handshake_server!(hash, info_blob, opts) do
    mode = Keyword.fetch!(opts, :mode)
    advertise? = Keyword.get(opts, :advertise_metadata_size?, true)
    ltep = Keyword.get(opts, :ltep, :ut_metadata)
    parent = self()
    metadata_size = byte_size(info_blob)
    remote_id = <<70::160>>

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      send(parent, {:handshake_listen, self(), listen})

      try do
        case :gen_tcp.accept(listen, @timeout) do
          {:ok, socket} ->
            serve_handshake_metadata(
              socket,
              hash,
              remote_id,
              info_blob,
              metadata_size,
              mode,
              advertise?,
              ltep
            )

          {:error, _} ->
            :ok
        end
      after
        :gen_tcp.close(listen)
      end
    end)

    assert_receive {:handshake_listen, _pid, ^listen}, @timeout
    {port, listen}
  end

  defp serve_handshake_metadata(
         socket,
         hash,
         remote_id,
         info_blob,
         metadata_size,
         mode,
         advertise?,
         ltep_mode
       ) do
    {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
      :gen_tcp.recv(socket, 68, @timeout)

    :ok =
      :gen_tcp.send(
        socket,
        [<<19>>, "BitTorrent protocol", Peer.reserved(), hash, remote_id]
      )

    {:ok, <<len::32>>} = :gen_tcp.recv(socket, 4, @timeout)
    {:ok, <<20, 0, _our_hs::binary>>} = :gen_tcp.recv(socket, len, @timeout)

    peer_hs =
      case {ltep_mode, advertise?} do
        {:no_ut_metadata, _} ->
          Bento.encode!(%{"m" => %{}})

        {_, true} ->
          Bento.encode!(%{
            "m" => %{"ut_metadata" => @peer_ut_id},
            "metadata_size" => metadata_size
          })

        {_, false} ->
          Bento.encode!(%{"m" => %{"ut_metadata" => @peer_ut_id}})
      end

    :ok = :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(0, peer_hs))
    {:ok, <<0, 0, 0, 1, id>>} = :gen_tcp.recv(socket, 5, @timeout)
    true = id == @interested_id
    :ok = :gen_tcp.send(socket, <<0, 0, 0, 1, Peer.Const.unchoke_id()>>)

    serve_metadata_requests(
      socket,
      %{info_blob: info_blob, total_size: metadata_size, mode: mode, served: %{}}
    )
  catch
    _, _ -> :ok
  after
    :gen_tcp.close(socket)
  end

  defp serve_metadata_requests(socket, ctx) do
    case recv_wire_frame_simple(socket) do
      {:ok, {:extended, @peer_ut_id, payload}} ->
        serve_metadata_requests(socket, handle_metadata_payload(socket, payload, ctx))

      _ ->
        ctx.served
    end
  end

  defp handle_metadata_payload(socket, payload, ctx) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: piece]}} ->
        respond_metadata_piece_request(socket, piece, ctx)

      _ ->
        ctx
    end
  end

  defp respond_metadata_piece_request(socket, piece, ctx) do
    case ctx.mode do
      :reject ->
        wire =
          Peer.LTEP.extended_message_wire(
            @local_ut_id,
            Magnet.UtMetadata.encode_reject(piece)
          )

        :gen_tcp.send(socket, wire)
        ctx

      :serve ->
        size = Magnet.UtMetadata.piece_byte_size(ctx.total_size, piece)
        offset = piece * Magnet.UtMetadata.block_size()
        data = binary_part(ctx.info_blob, offset, size)
        send_ut_data(socket, piece, ctx.total_size, data)
        %{ctx | served: Map.put(ctx.served, piece, true)}
    end
  end

  defp recv_wire_frame_simple(socket) do
    case :gen_tcp.recv(socket, 4, @timeout) do
      {:ok, <<len::32>>} when len >= 2 ->
        case :gen_tcp.recv(socket, len, @timeout) do
          {:ok, <<20, ext_id, payload::binary>>} -> {:ok, {:extended, ext_id, payload}}
          other -> other
        end

      other ->
        other
    end
  end

  defp start_plain_handshake_server!(hash, opts) do
    extension? = Keyword.fetch!(opts, :extension?)
    parent = self()
    remote_id = <<71::160>>

    reserved =
      if extension? do
        Peer.reserved()
      else
        <<0::64>>
      end

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      send(parent, {:plain_listen, listen})

      try do
        case :gen_tcp.accept(listen, @timeout) do
          {:ok, socket} ->
            {:ok, <<19, "BitTorrent protocol"::binary, _::binary>>} =
              :gen_tcp.recv(socket, 68, @timeout)

            :gen_tcp.send(
              socket,
              [<<19>>, "BitTorrent protocol", reserved, hash, remote_id]
            )

          {:error, _} ->
            :ok
        end
      after
        :gen_tcp.close(listen)
      end
    end)

    assert_receive {:plain_listen, ^listen}, @timeout
    {port, listen}
  end

  defp with_metadata_peer(hash, wire_blob, metadata_size, fun) do
    with_metadata_peers(
      hash,
      [{<<9::160>>, {:metadata, wire_blob, metadata_size, mode: :serve}}],
      fn _keys, refs ->
        key = Peer.make_key(hash, <<9::160>>)
        fun.(key, Map.fetch!(refs, <<9::160>>))
      end
    )
  end

  defp with_metadata_peers(hash, peer_specs, fun) do
    {model_pid, servers} = setup_metadata_peers(hash, peer_specs)
    await_metadata_servers_ready(servers)

    on_exit(fn ->
      stop_swarm(hash)
      TestSupport.Sync.safe_stop(model_pid, @timeout)
    end)

    keys = Map.keys(servers) |> Enum.map(&Peer.make_key(hash, &1))
    fun.(keys, servers)
  end

  defp setup_metadata_peers(hash, peer_specs) do
    torrent = sample_torrent(hash, 4)
    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    start_swarm(hash)

    servers =
      Enum.reduce(peer_specs, %{}, fn spec, acc ->
        case spec do
          {id, {:metadata, wire_blob, metadata_size, meta_opts}} ->
            install_metadata_peer(acc, hash, id, wire_blob, metadata_size, meta_opts)
        end
      end)

    {model_pid, servers}
  end

  defp await_metadata_servers_ready(servers) do
    for {_id, ref} <- servers, is_pid(ref) do
      assert_receive {:metadata_server_ready, ^ref}, @timeout
    end
  end

  defp install_metadata_peer(acc, hash, id, wire_blob, metadata_size, meta_opts) do
    {client, server, listen} = loopback_sockets()
    mode = Keyword.get(meta_opts, :mode, :serve)
    register_loopback_cleanup(client, server, listen)

    assert {:ok, _peer_sup} = Torrent.Swarm.add(hash, id, Peer.reserved(), client)
    key = Peer.make_key(hash, id)
    assert :ok = Peer.Sender.activate(key)

    ltep = ltep_with_ut_metadata(metadata_size: metadata_size)

    replace_controller_state(key, fn state ->
      %{state | ltep: ltep, choke_me: false, bitfield: nil}
    end)

    server_ref =
      case mode do
        :silent ->
          send(self(), {:metadata_server_ready, server})
          server

        _ ->
          start_swarm_metadata_server(server, wire_blob, mode: mode)
      end

    Map.put(acc, id, server_ref)
  end

  defp start_swarm_metadata_server(server, info_blob, opts) do
    mode = Keyword.fetch!(opts, :mode)
    parent = self()
    total_size = byte_size(info_blob)

    Task.async(fn ->
      send(parent, {:metadata_server_ready, self()})
      serve_swarm_ut_metadata(server, info_blob, total_size, mode)
    end).pid
  end

  defp serve_swarm_ut_metadata(server, info_blob, total_size, mode) do
    ctx = %{
      info_blob: info_blob,
      total_size: total_size,
      mode: mode,
      test_pid: self()
    }

    loop = fn loop ->
      case recv_swarm_wire_frame(server) do
        {:ok, {:standard, msg_id, _payload}} when msg_id == @interested_id ->
          loop.(loop)

        {:ok, {:extended, @swarm_peer_ut_id, payload}} ->
          handle_swarm_ut_metadata_request(server, payload, ctx, loop)

        {:error, :closed} ->
          :ok

        _ ->
          :ok
      end
    end

    loop.(loop)
  end

  defp handle_swarm_ut_metadata_request(server, payload, ctx, loop) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: piece]}} ->
        respond_swarm_metadata_piece(server, piece, ctx, loop)

      _ ->
        loop.(loop)
    end
  end

  defp respond_swarm_metadata_piece(server, piece, ctx, loop) do
    case ctx.mode do
      :reject ->
        wire =
          Peer.LTEP.extended_message_wire(
            @local_ut_id,
            Magnet.UtMetadata.encode_reject(piece)
          )

        :gen_tcp.send(server, wire)
        loop.(loop)

      :serve ->
        offset = piece * Magnet.UtMetadata.block_size()
        size = Magnet.UtMetadata.piece_byte_size(ctx.total_size, piece)
        data = binary_part(ctx.info_blob, offset, size)
        send_ut_data(server, piece, ctx.total_size, data)
        loop.(loop)

      :silent ->
        :ok
    end
  end

  defp recv_swarm_wire_frame(socket) do
    case recv_swarm_wire_length(socket) do
      {:ok, :keepalive} -> recv_swarm_wire_frame(socket)
      {:ok, len} when len >= 1 -> decode_swarm_wire_frame_body(socket, len)
      {:error, :closed} -> {:error, :closed}
      {:error, _} = error -> error
    end
  end

  defp recv_swarm_wire_length(socket) do
    case :gen_tcp.recv(socket, 4, @timeout) do
      {:ok, <<0, 0, 0, 0>>} -> {:ok, :keepalive}
      {:ok, <<len::32>>} -> {:ok, len}
      error -> error
    end
  end

  defp decode_swarm_wire_frame_body(socket, len) do
    case :gen_tcp.recv(socket, len, @timeout) do
      {:ok, <<20, ext_id, payload::binary>>} when len >= 2 ->
        {:ok, {:extended, ext_id, payload}}

      {:ok, <<msg_id>>} when len == 1 ->
        {:ok, {:standard, msg_id, <<>>}}

      {:ok, <<msg_id, rest::binary>>} ->
        {:ok, {:standard, msg_id, rest}}

      {:error, _} = error ->
        error
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
      pid -> TestSupport.Sync.safe_stop(pid, @timeout)
    end
  end

  defp with_open_swarm_stack(hash, fun) do
    {model_pid, client, server, listen, key} = setup_open_swarm_stack(hash)
    register_open_swarm_stack_cleanup(client, server, listen, hash, model_pid)

    assert {:ok, peer_sup} = Torrent.Swarm.add(hash, <<8::160>>, Peer.reserved(), client)
    sender = Peer.sender_pid(peer_sup)
    assert :ok = Peer.Transport.controlling_process(client, sender)
    assert :ok = Peer.Sender.activate(key)

    fun.(key, server)
  end

  defp setup_open_swarm_stack(hash) do
    torrent = sample_torrent(hash, 4)
    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    start_swarm(hash)

    {client, server, listen} = loopback_sockets()
    id = <<8::160>>
    key = Peer.make_key(hash, id)

    {model_pid, client, server, listen, key}
  end

  defp register_open_swarm_stack_cleanup(client, server, listen, hash, model_pid) do
    on_exit(fn ->
      for sock <- [client, server, listen], do: close_quietly(sock)
      stop_swarm(hash)
      TestSupport.Sync.safe_stop(model_pid, @timeout)
    end)
  end

  defp ltep_with_ut_metadata(opts) do
    metadata_size = Keyword.get(opts, :metadata_size)

    hs =
      if is_integer(metadata_size) do
        Handshake.from_map(%{"m" => %{"ut_metadata" => 2}, "metadata_size" => metadata_size})
      else
        Handshake.from_map(%{"m" => %{"ut_metadata" => 2}})
      end

    Session.new([UtMetadataExtension]) |> Session.apply_peer_handshake(hs)
  end

  defp replace_controller_state(key, fun) when is_function(fun, 1) do
    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fun)
  end

  defp sender_active?(key) do
    :sys.get_state({:via, Registry, {Registry, {key, Peer.Sender}}}).active
  end

  defp loopback_sockets do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    {:ok, client} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])

    {:ok, server} = :gen_tcp.accept(listen, @timeout)
    {client, server, listen}
  end

  defp register_loopback_cleanup(client, server, listen) do
    on_exit(fn ->
      Enum.each([client, server, listen], &close_quietly/1)
    end)
  end

  defp close_quietly(socket) do
    :gen_tcp.close(socket)
  catch
    _, _ -> :ok
  end

  defp sample_torrent(hash, pieces_count) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "magnet-cycle2", "piece length" => @piece_len}},
      left: pieces_count * @piece_len,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(pieces_count),
      peer_status: nil
    }
  end
end

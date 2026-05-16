defmodule MagnetConnectedMetadataTest do
  use ExUnit.Case, async: false

  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias Peer.LTEP.{Handshake, Session}

  @interested_id Peer.Const.interested_id()
  @timeout 5_000
  @piece_len 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)

    previous_connected = Application.get_env(:elixir_torrent, :magnet_connected_metadata, [])
    previous_connection = Application.get_env(:elixir_torrent, :magnet_connection, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :magnet_connected_metadata, previous_connected)
      Application.put_env(:elixir_torrent, :magnet_connection, previous_connection)
    end)

    :ok
  end

  describe "ConnectedMetadata.fetch/2" do
    setup do
      short_connected_env!()
      short_connection_env!()
      :ok
    end

    test "happy path fetches metadata over swarm, verifies hash, writes .torrent, reactivates Sender" do
      {info_map, info_blob, hash} = build_info_blob!(name: "connected-md-e2e", private: true)
      metadata_size = byte_size(info_blob)
      magnet = %Magnet{hash: hash, trackers: ["http://tracker.example/ann"], display_name: "e2e"}
      path = Magnet.Fetcher.torrent_path(hash)
      on_exit(fn -> File.rm(path) end)

      with_metadata_peer(hash, info_blob, metadata_size, fn key, server_ref ->
        assert {:ok, ^path, trackers, true} =
                 Magnet.ConnectedMetadata.fetch(magnet, ["http://tracker.example/ann"])

        assert trackers == ["http://tracker.example/ann"]
        assert File.exists?(path)
        assert File.read!(path) == Magnet.build_torrent!(magnet, info_blob)

        assert {:ok, decoded, ^info_blob} =
                 Magnet.UtMetadata.decode_and_verify_info(info_blob, hash)

        assert decoded["name"] == info_map["name"]
        assert sender_active?(key)

        assert_receive {:ut_metadata_request, ^server_ref, 0, request_payload}, @timeout
        assert request_payload == Magnet.UtMetadata.encode_request(0)
        assert_receive {:ut_metadata_data_sent, ^server_ref, 0, ^metadata_size}, @timeout
      end)
    end

    test "returns info_hash_mismatch when ut_metadata payload does not match the magnet hash" do
      {info_map, info_blob, hash} = build_info_blob!(name: "1234567890")
      metadata_size = byte_size(info_blob)
      wrong_blob = Bento.encode!(Map.put(info_map, "name", "0987654321"))
      assert byte_size(wrong_blob) == metadata_size

      magnet = %Magnet{hash: hash, trackers: [], display_name: "mismatch"}

      with_metadata_peer(hash, wrong_blob, metadata_size, fn key, _server_ref ->
        assert {:error, :info_hash_mismatch} = Magnet.ConnectedMetadata.fetch(magnet, [])
        assert sender_active?(key)
      end)
    end

    test "aggregates timeout and metadata_rejected failures across swarm peers" do
      {_, info_blob, hash} = build_info_blob!(name: "aggregate")
      metadata_size = byte_size(info_blob)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "aggregate"}

      with_metadata_peers(
        hash,
        [
          {<<10::160>>, {:metadata, info_blob, metadata_size, mode: :silent}},
          {<<11::160>>, {:metadata, info_blob, metadata_size, mode: :reject}}
        ],
        fn keys, _refs ->
          timeout_key = Peer.make_key(hash, <<10::160>>)
          reject_key = Peer.make_key(hash, <<11::160>>)

          assert timeout_key in keys
          assert reject_key in keys

          Application.put_env(
            :elixir_torrent,
            :magnet_connection,
            Keyword.put(
              Application.get_env(:elixir_torrent, :magnet_connection, []),
              :recv_timeout_ms,
              300
            )
          )

          assert {:error, {:metadata_unavailable, failures}} =
                   Magnet.ConnectedMetadata.fetch(magnet, [])

          assert Enum.sort(failures) == [:metadata_rejected, :timeout]
          refute :metadata_size_pending in failures
          refute :peer_died in failures

          assert sender_active?(timeout_key)
          assert sender_active?(reject_key)
        end
      )
    end

    test "peer death during wire fetch normalizes to peer_died, not metadata_size_pending" do
      {_, info_blob, hash} = build_info_blob!(name: "peer-died")
      metadata_size = byte_size(info_blob)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "peer-died"}

      with_metadata_peer(
        hash,
        info_blob,
        metadata_size,
        [on_request: :close_on_request],
        fn _key, server_ref ->
          fetch_task = Task.async(fn -> Magnet.ConnectedMetadata.fetch(magnet, []) end)

          assert_receive {:ut_metadata_request, ^server_ref, 0, _}, @timeout

          assert {:error, {:metadata_unavailable, failures}} = Task.await(fetch_task, @timeout)
          assert :peer_died in failures
          refute :metadata_size_pending in failures
        end
      )
    end

    test "returns no_swarm_metadata_peers when the swarm has no metadata-capable peers" do
      hash = :crypto.strong_rand_bytes(20)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "no-peers"}

      Application.put_env(:elixir_torrent, :magnet_connected_metadata,
        wait_for_peers_ms: 1,
        wait_poll_ms: 1,
        wait_max_ms: 1,
        min_peers_gather_ms: 1,
        min_peers_for_round: 4
      )

      assert {:error, :no_swarm_metadata_peers} =
               Magnet.ConnectedMetadata.fetch(magnet, ["http://example.invalid/announce"])
    end
  end

  describe "Bootstrap metadata peer discovery" do
    test "metadata_peer_keys excludes peers without LTEP and filters by ut_metadata candidacy" do
      hash = :crypto.strong_rand_bytes(20)

      with_swarm_peers(
        hash,
        [
          {<<1::160>>, :no_ltep},
          {<<2::160>>, {:ut_metadata, metadata_size: 8192}},
          {<<3::160>>, {:ut_metadata, metadata_size: nil}}
        ],
        fn keys_by_id ->
          keys = Magnet.Bootstrap.metadata_peer_keys(hash)
          assert length(keys) == 2
          assert Peer.make_key(hash, <<2::160>>) in keys
          assert Peer.make_key(hash, <<3::160>>) in keys
          refute Peer.make_key(hash, <<1::160>>) in keys

          sized_info = Map.fetch!(keys_by_id, <<2::160>>)
          bare_info = Map.fetch!(keys_by_id, <<3::160>>)

          assert Magnet.Bootstrap.metadata_peer_candidate?(sized_info)
          assert Magnet.Bootstrap.metadata_peer_eligible?(sized_info)
          assert sized_info.metadata_size == 8192

          assert Magnet.Bootstrap.metadata_peer_candidate?(bare_info)
          refute Magnet.Bootstrap.metadata_peer_eligible?(bare_info)
        end
      )
    end

    test "metadata_peer_eligible accepts seeder peers without metadata_size" do
      hash = :crypto.strong_rand_bytes(20)
      pieces = 4
      bf = full_bitfield(pieces)

      with_swarm_peers(hash, [{<<4::160>>, {:ut_metadata_seeder, bitfield: bf}}], fn keys_by_id ->
        key = Peer.make_key(hash, <<4::160>>)
        assert Magnet.Bootstrap.metadata_peer_keys(hash) == [key]

        info = Map.fetch!(keys_by_id, <<4::160>>)
        assert Magnet.Bootstrap.metadata_peer_candidate?(info)
        assert Magnet.Bootstrap.metadata_peer_eligible?(info)
        assert info.seeder?
        assert info.metadata_size == nil
      end)
    end
  end

  describe "Connection.open_swarm/2 and close_swarm/1" do
    setup do
      Application.put_env(:elixir_torrent, :magnet_connection,
        unchoke_wait_ms: 1,
        controller_unchoke_poll_ms: 1
      )

      :ok
    end

    test "metadata_size path deactivates Sender and returns a swarm connection without unchoke" do
      hash = :crypto.strong_rand_bytes(20)

      with_open_swarm_stack(hash, fn key, server ->
        ltep = ltep_with_ut_metadata(metadata_size: 4096)

        replace_controller_state(key, fn state ->
          %{state | ltep: ltep, choke_me: true, bitfield: nil}
        end)

        assert {:ok, info} = Peer.Controller.metadata_capable(key)
        refute info.unchoked?

        assert {:ok, conn} = Magnet.Connection.open_swarm(key, info)
        refute sender_active?(key)

        assert conn.transport == :swarm
        assert conn.peer_key == key
        assert conn.hash == hash
        assert conn.metadata_size == 4096
        assert conn.unchoked? == false
        assert Session.peer_supports?(conn.ltep, Magnet.UtMetadata.extension_name())

        assert {:ok, <<0, 0, 0, 1, 2>>} = :gen_tcp.recv(server, 5, @timeout)

        assert :ok = Magnet.Connection.close_swarm(key)
        assert sender_active?(key)
      end)
    end

    test "seeder without metadata_size opens swarm and leaves metadata_size nil" do
      hash = :crypto.strong_rand_bytes(20)
      bf = full_bitfield(4)

      with_open_swarm_stack(hash, fn key, _server ->
        ltep =
          Session.new([UtMetadataExtension])
          |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_metadata" => 2}}))

        replace_controller_state(key, fn state ->
          %{state | ltep: ltep, bitfield: bf, choke_me: false}
        end)

        assert {:ok, info} = Peer.Controller.metadata_capable(key)
        assert info.seeder?
        assert info.metadata_size == nil

        assert {:ok, conn} = Magnet.Connection.open_swarm(key, info)
        refute sender_active?(key)
        assert conn.metadata_size == nil
        assert conn.unchoked? == true

        assert :ok = Magnet.Connection.close(conn)
        assert sender_active?(key)
      end)
    end

    test "ut_metadata without metadata_size or seeder still opens for BEP 9 piece-0 probe" do
      hash = :crypto.strong_rand_bytes(20)

      with_open_swarm_stack(hash, fn key, _server ->
        ltep =
          Session.new([UtMetadataExtension])
          |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_metadata" => 3}}))

        replace_controller_state(key, fn state ->
          %{state | ltep: ltep, bitfield: nil, choke_me: false}
        end)

        assert {:ok, info} = Peer.Controller.metadata_capable(key)
        refute info.seeder?
        assert info.metadata_size == nil

        assert {:ok, conn} = Magnet.Connection.open_swarm(key, info)
        refute sender_active?(key)
        assert conn.metadata_size == nil

        assert :ok = Magnet.Connection.close_swarm(key)
        assert sender_active?(key)
      end)
    end

    test "returns no_ut_metadata when LTEP lacks ut_metadata after controller_ready" do
      hash = :crypto.strong_rand_bytes(20)

      with_open_swarm_stack(hash, fn key, _server ->
        ltep = Session.new([UtMetadataExtension])
        bf = full_bitfield(4)

        replace_controller_state(key, fn state ->
          %{state | ltep: ltep, bitfield: bf, choke_me: false}
        end)

        info = %{
          ltep: ltep,
          metadata_size: nil,
          unchoked?: true,
          seeder?: true
        }

        assert sender_active?(key)
        assert {:error, :no_ut_metadata} = Magnet.Connection.open_swarm(key, info)
        assert sender_active?(key)
      end)
    end

    test "returns noproc when Sender is gone before deactivate" do
      hash = :crypto.strong_rand_bytes(20)

      with_open_swarm_stack(hash, fn key, _server ->
        ltep = ltep_with_ut_metadata(metadata_size: 2048)

        replace_controller_state(key, fn state ->
          %{state | ltep: ltep, choke_me: false}
        end)

        assert {:ok, info} = Peer.Controller.metadata_capable(key)
        sender_pid = sender_pid(key)
        assert :ok = TestSupport.Sync.safe_stop(sender_pid, @timeout)

        assert {:error, :noproc} = Magnet.Connection.open_swarm(key, info)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp short_connected_env!(overrides \\ []) do
    defaults = [
      wait_for_peers_ms: 50,
      wait_poll_ms: 1,
      wait_max_ms: 50,
      min_peers_gather_ms: 1,
      min_peers_for_round: 1,
      max_peers: 4,
      metadata_parallel: 4,
      peer_timeout_ms: 10_000,
      ltep_metadata_wait_ms: 50
    ]

    Application.put_env(
      :elixir_torrent,
      :magnet_connected_metadata,
      Keyword.merge(defaults, overrides)
    )
  end

  defp short_connection_env!(overrides \\ []) do
    defaults = [
      unchoke_wait_ms: 50,
      controller_unchoke_poll_ms: 1,
      recv_timeout_ms: 5_000
    ]

    Application.put_env(
      :elixir_torrent,
      :magnet_connection,
      Keyword.merge(defaults, overrides)
    )
  end

  defp build_info_blob!(opts) do
    name = Keyword.get(opts, :name, "connected-md")
    private? = Keyword.get(opts, :private, false)

    info = %{
      "name" => name,
      "length" => Keyword.get(opts, :length, 128),
      "piece length" => @piece_len,
      "pieces" => <<0::160>>
    }

    info = if private?, do: Map.put(info, "private", 1), else: info
    blob = Bento.encode!(info)
    {info, blob, :crypto.hash(:sha, blob)}
  end

  defp with_metadata_peer(hash, wire_blob, metadata_size, opts_or_fun, fun \\ nil)

  defp with_metadata_peer(hash, wire_blob, metadata_size, fun, nil) when is_function(fun, 2) do
    with_metadata_peer(hash, wire_blob, metadata_size, [], fun)
  end

  defp with_metadata_peer(hash, wire_blob, metadata_size, opts, fun) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :serve)
    on_request = Keyword.get(opts, :on_request)

    with_metadata_peers(
      hash,
      [{<<9::160>>, {:metadata, wire_blob, metadata_size, mode: mode, on_request: on_request}}],
      fn _keys, refs ->
        key = Peer.make_key(hash, <<9::160>>)
        fun.(key, Map.fetch!(refs, <<9::160>>))
      end
    )
  end

  defp with_metadata_peers(hash, peer_specs, fun) do
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

    for {_id, ref} <- servers, is_pid(ref) do
      assert_receive {:metadata_server_ready, ^ref}, @timeout
    end

    on_exit(fn ->
      stop_swarm(hash)
      TestSupport.Sync.safe_stop(model_pid, @timeout)
    end)

    keys = Map.keys(servers) |> Enum.map(&Peer.make_key(hash, &1))
    fun.(keys, servers)
  end

  defp install_metadata_peer(acc, hash, id, wire_blob, metadata_size, meta_opts) do
    {client, server, listen} = loopback_sockets()
    mode = Keyword.get(meta_opts, :mode, :serve)
    on_request = Keyword.get(meta_opts, :on_request)
    register_loopback_cleanup(client, server, listen)

    assert {:ok, _peer_sup} = Torrent.Swarm.add(hash, id, Peer.reserved(), client)
    key = Peer.make_key(hash, id)
    assert :ok = Peer.Sender.activate(key)

    ltep = ltep_with_ut_metadata(metadata_size: metadata_size)

    replace_controller_state(key, fn state ->
      %{state | ltep: ltep, choke_me: false, bitfield: nil}
    end)

    server_ref = metadata_peer_server_ref(server, wire_blob, mode, on_request)
    Map.put(acc, id, server_ref)
  end

  defp metadata_peer_server_ref(server, _wire_blob, :silent, _on_request) do
    send(self(), {:metadata_server_ready, server})
    server
  end

  defp metadata_peer_server_ref(server, wire_blob, mode, on_request) do
    task =
      start_swarm_metadata_server(server, wire_blob, mode: mode, on_request: on_request)

    task.pid
  end

  defp register_loopback_cleanup(client, server, listen) do
    on_exit(fn -> close_loopback_sockets(client, server, listen) end)
  end

  defp close_loopback_sockets(client, server, listen) do
    Enum.each([client, server, listen], &close_quietly/1)
  end

  defp start_swarm_metadata_server(server, info_blob, opts) do
    mode = Keyword.get(opts, :mode, :serve)
    on_request = Keyword.get(opts, :on_request)
    parent = self()
    total_size = byte_size(info_blob)
    peer_ut_id = 2
    local_ut_id = UtMetadataExtension.local_id()

    Task.async(fn ->
      send(parent, {:metadata_server_ready, self()})

      serve_swarm_ut_metadata(server, info_blob, total_size, peer_ut_id, local_ut_id, %{
        mode: mode,
        on_request: on_request,
        test_pid: parent
      })
    end)
  end

  defp serve_swarm_ut_metadata(
         server,
         info_blob,
         total_size,
         peer_ut_id,
         local_ut_id,
         opts
       ) do
    ctx = swarm_metadata_ctx(info_blob, total_size, local_ut_id, opts)

    loop = fn loop ->
      case recv_wire_frame(server) do
        {:ok, {:standard, msg_id, _payload}} when msg_id == @interested_id ->
          loop.(loop)

        {:ok, {:extended, ^peer_ut_id, payload}} ->
          handle_ut_metadata_request(server, payload, ctx, loop)

        {:error, :closed} ->
          :ok

        {:error, _} ->
          :ok

        :closed ->
          :ok
      end
    end

    loop.(loop)
  end

  defp swarm_metadata_ctx(info_blob, total_size, local_ut_id, opts) do
    %{
      info_blob: info_blob,
      total_size: total_size,
      local_ut_id: local_ut_id,
      mode: Map.fetch!(opts, :mode),
      on_request: Map.get(opts, :on_request),
      test_pid: Map.fetch!(opts, :test_pid)
    }
  end

  defp handle_ut_metadata_request(server, payload, ctx, loop) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: piece]}} ->
        dispatch_ut_metadata_request(server, piece, payload, ctx, loop)

      _ ->
        loop.(loop)
    end
  end

  defp dispatch_ut_metadata_request(server, piece, payload, ctx, loop) do
    send(ctx.test_pid, {:ut_metadata_request, self(), piece, payload})
    run_metadata_on_request_hook(ctx.on_request, server)
    respond_ut_metadata_request(server, piece, ctx, loop)
  end

  defp run_metadata_on_request_hook(:close_on_request, server) do
    :gen_tcp.close(server)
    :ok
  end

  defp run_metadata_on_request_hook({:kill_sender, release}, _server) do
    receive do
      ^release -> :ok
    end
  end

  defp run_metadata_on_request_hook(_, _server), do: :ok

  defp respond_ut_metadata_request(server, piece, ctx, loop) do
    case {ctx.mode, ctx.on_request} do
      {:serve, :close_on_request} ->
        :ok

      {:serve, _} ->
        send_metadata_piece(server, ctx.info_blob, ctx.total_size, piece, ctx.local_ut_id)
        send(ctx.test_pid, {:ut_metadata_data_sent, self(), piece, ctx.total_size})
        loop.(loop)

      {:reject, _} ->
        reject =
          Peer.LTEP.extended_message_wire(
            ctx.local_ut_id,
            Magnet.UtMetadata.encode_reject(piece)
          )

        :ok = :gen_tcp.send(server, reject)
        loop.(loop)

      {:silent, _} ->
        receive do
        after
          :infinity -> :ok
        end
    end
  end

  defp send_metadata_piece(socket, info_blob, total_size, piece, local_ut_id) do
    offset = piece * Magnet.UtMetadata.block_size()
    size = Magnet.UtMetadata.piece_byte_size(total_size, piece)
    data = binary_part(info_blob, offset, size)

    wire =
      Peer.LTEP.extended_message_wire(
        local_ut_id,
        Magnet.UtMetadata.encode_data(piece, total_size, data)
      )

    :ok = :gen_tcp.send(socket, wire)
  end

  defp recv_wire_frame(socket) do
    case :gen_tcp.recv(socket, 4, @timeout) do
      {:ok, <<0, 0, 0, 0>>} ->
        recv_wire_frame(socket)

      {:ok, <<len::32>>} when len >= 1 ->
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

      {:error, :closed} ->
        :closed

      {:error, _} = error ->
        error
    end
  end

  defp with_swarm_peers(hash, peer_specs, fun) do
    torrent = sample_torrent(hash, 4)
    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    start_swarm(hash)

    on_exit(fn ->
      stop_swarm(hash)
      TestSupport.Sync.safe_stop(model_pid, @timeout)
    end)

    keys_by_id =
      peer_specs
      |> Enum.map(&setup_swarm_peer_entry(hash, &1))
      |> Map.new()

    fun.(keys_by_id)
  end

  defp setup_swarm_peer_entry(hash, {id, spec}) do
    {client, server, listen} = loopback_sockets()
    register_loopback_cleanup(client, server, listen)

    assert {:ok, _peer_sup} = Torrent.Swarm.add(hash, id, Peer.reserved(), client)
    key = Peer.make_key(hash, id)
    assert :ok = Peer.Sender.activate(key)
    configure_swarm_peer_ltep(key, spec)
    {id, swarm_peer_metadata_info(key)}
  end

  defp configure_swarm_peer_ltep(_key, :no_ltep), do: :ok

  defp configure_swarm_peer_ltep(key, {:ut_metadata, opts}) do
    ltep = ltep_with_ut_metadata(opts)
    replace_controller_state(key, &Map.put(&1, :ltep, ltep))
  end

  defp configure_swarm_peer_ltep(key, {:ut_metadata_seeder, opts}) do
    ltep = ltep_ut_metadata_seeder()
    bitfield = Keyword.fetch!(opts, :bitfield)
    replace_controller_state(key, &%{&1 | ltep: ltep, bitfield: bitfield})
  end

  defp ltep_ut_metadata_seeder do
    Session.new([UtMetadataExtension])
    |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_metadata" => 2}}))
  end

  defp swarm_peer_metadata_info(key) do
    case Peer.Controller.metadata_capable(key) do
      {:ok, capable} -> capable
      :error -> nil
    end
  end

  defp with_open_swarm_stack(hash, fun) do
    torrent = sample_torrent(hash, 4)
    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    start_swarm(hash)

    {client, server, listen} = loopback_sockets()
    id = <<8::160>>
    key = Peer.make_key(hash, id)

    on_exit(fn ->
      for sock <- [client, server, listen] do
        close_quietly(sock)
      end

      stop_swarm(hash)
      TestSupport.Sync.safe_stop(model_pid, @timeout)
    end)

    assert {:ok, peer_sup} = Torrent.Swarm.add(hash, id, Peer.reserved(), client)
    sender = Peer.sender_pid(peer_sup)
    assert :ok = Peer.Transport.controlling_process(client, sender)
    assert :ok = Peer.Sender.activate(key)

    fun.(key, server)
  end

  defp sample_torrent(hash, pieces_count) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "magnet-connected-md", "piece length" => @piece_len}},
      left: pieces_count * @piece_len,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(pieces_count),
      peer_status: nil
    }
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

  defp loopback_sockets do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn(fn ->
      case :gen_tcp.accept(listen, @timeout) do
        {:ok, server} ->
          _ = :gen_tcp.controlling_process(server, parent)
          send(parent, {:loopback_server, server})

        error ->
          send(parent, {:loopback_accept_error, error})
      end
    end)

    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)

    receive do
      {:loopback_server, server} -> {client, server, listen}
      {:loopback_accept_error, error} -> flunk("accept failed: #{inspect(error)}")
    after
      @timeout -> flunk("accept timed out")
    end
  end

  defp ltep_with_ut_metadata(opts) do
    metadata_size = Keyword.get(opts, :metadata_size, 4096)

    peer_map =
      if metadata_size do
        %{"m" => %{"ut_metadata" => 2}, "metadata_size" => metadata_size}
      else
        %{"m" => %{"ut_metadata" => 2}}
      end

    Session.new([UtMetadataExtension])
    |> Session.apply_peer_handshake(Handshake.from_map(peer_map))
  end

  defp full_bitfield(pieces_count) do
    Enum.reduce(0..(pieces_count - 1), Torrent.Bitfield.make(pieces_count), fn index, bf ->
      Torrent.Bitfield.set(bf, index, 1)
    end)
  end

  defp replace_controller_state(key, fun) when is_function(fun, 1) do
    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fun)
  end

  defp sender_active?(key) do
    :sys.get_state({:via, Registry, {Registry, {key, Peer.Sender}}}).active
  end

  defp sender_pid(key) do
    GenServer.whereis({:via, Registry, {Registry, {key, Peer.Sender}}})
  end

  defp close_quietly(sock) when is_port(sock) do
    :gen_tcp.close(sock)
  catch
    :error, _ -> :ok
  end
end

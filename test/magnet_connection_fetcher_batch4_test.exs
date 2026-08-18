defmodule Magnet.ConnectionFetcherBatch4Test do
  use ExUnit.Case, async: false

  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias Peer.LTEP.{Handshake, Session}

  @timeout 1_000
  @recv_fast_ms 200
  @peer_ut_id 7
  @local_ut_id UtMetadataExtension.local_id()

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)

    previous_connection = Application.get_env(:elixir_torrent, :magnet_connection, [])
    previous_connected = Application.get_env(:elixir_torrent, :magnet_connected_metadata, [])
    previous_fetcher = Application.get_env(:elixir_torrent, :magnet_fetcher, [])
    previous_dht = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :magnet_connection, previous_connection)
      Application.put_env(:elixir_torrent, :magnet_connected_metadata, previous_connected)
      Application.put_env(:elixir_torrent, :magnet_fetcher, previous_fetcher)
      Application.put_env(:elixir_torrent, :dht, previous_dht)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)
    short_connection_env!()
    :ok
  end

  describe "Connection.request_piece/2 wire paths" do
    test "returns reject when peer sends ut_metadata reject" do
      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, payload} = recv_extended_request(server)
        assert {:ok, {:request, [piece: 0]}} = Magnet.UtMetadata.decode_message(payload)
        send_ut_reject(server, 0)
        :gen_tcp.close(server)
      end)

      conn = ut_metadata_conn(client, total_size: 100, unchoked?: true)

      assert {:reject, 0} = Magnet.Connection.request_piece(conn, 0)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "ignores wrong-piece data then accepts matching piece" do
      total_size = 100
      data = :binary.copy(<<0xAB>>, total_size)

      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, payload} = recv_extended_request(server)
        assert {:ok, {:request, [piece: 0]}} = Magnet.UtMetadata.decode_message(payload)

        send_ut_data(server, 1, total_size, :binary.copy(<<0>>, total_size))
        send_ut_data(server, 0, total_size, data)
        :gen_tcp.close(server)
      end)

      conn = ut_metadata_conn(client, total_size: total_size, unchoked?: true)
      assert {:ok, ^data, ^total_size} = Magnet.Connection.request_piece(conn, 0)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "ignores malformed extended payload then accepts valid data" do
      total_size = 64
      data = :binary.copy(<<0xCD>>, total_size)

      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, payload} = recv_extended_request(server)
        assert {:ok, {:request, [piece: 0]}} = Magnet.UtMetadata.decode_message(payload)

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

    test "returns invalid_piece_size when data length does not match total_size" do
      total_size = 100
      short = :binary.copy(<<0>>, 10)

      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, _payload} = recv_extended_request(server)
        send_ut_data(server, 0, total_size, short)
        :gen_tcp.close(server)
      end)

      conn = ut_metadata_conn(client, total_size: total_size, unchoked?: true)
      assert {:error, :invalid_piece_size} = Magnet.Connection.request_piece(conn, 0)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "choked connection still receives ut_metadata reply on wire" do
      total_size = 80
      data = :binary.copy(<<0xEE>>, total_size)

      Application.put_env(:elixir_torrent, :magnet_connection,
        unchoke_wait_ms: 80,
        unchoke_stable_ms: 0,
        recv_timeout_ms: @timeout
      )

      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, payload} = recv_extended_request(server)
        assert {:ok, {:request, [piece: 0]}} = Magnet.UtMetadata.decode_message(payload)
        send_ut_data(server, 0, total_size, data)
        :gen_tcp.close(server)
      end)

      conn = ut_metadata_conn(client, total_size: total_size, unchoked?: false)
      assert {:ok, ^data, ^total_size} = Magnet.Connection.request_piece(conn, 0)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "returns timeout when peer sends no ut_metadata reply" do
      Application.put_env(:elixir_torrent, :magnet_connection, recv_timeout_ms: @recv_fast_ms)

      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        {:ok, _payload} = recv_extended_request(server)
        :gen_tcp.recv(server, 1, @timeout)
      end)

      conn = ut_metadata_conn(client, total_size: 50, unchoked?: true)
      assert {:error, :timeout} = Magnet.Connection.request_piece(conn, 0)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "returns closed when socket is dead" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      {:ok, client} =
        :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])

      :ok = :gen_tcp.close(client)
      :gen_tcp.close(listen)

      conn = ut_metadata_conn(client, total_size: 50, unchoked?: true)
      assert {:error, reason} = Magnet.Connection.request_piece(conn, 0)
      assert reason in [:closed, :einval, :enotconn]
    end
  end

  describe "Connection.fetch_metadata/2" do
    test "returns metadata_rejected when peer rejects piece zero" do
      hash = :crypto.strong_rand_bytes(20)

      info = %{
        "name" => "reject-md",
        "length" => 64,
        "piece length" => 16_384,
        "pieces" => <<0::160>>
      }

      info_blob = Bento.encode!(info)

      {port, _listen_ref} = start_handshake_server!(hash, info_blob, mode: :reject)

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      assert {:error, :metadata_rejected} = Magnet.Connection.fetch_metadata(peer, hash)
    end

    test "returns metadata_size_mismatch when later piece reports different total_size" do
      hash = :crypto.strong_rand_bytes(20)
      pad = 18_000

      info = %{
        "name" => "two-piece",
        "length" => pad + 50,
        "piece length" => 16_384,
        "pieces" => :binary.copy(<<0::160>>, 2),
        "pad" => :binary.copy(<<0>>, pad)
      }

      info_blob = Bento.encode!(info)
      metadata_size = byte_size(info_blob)
      assert metadata_size > 16_384

      {port, _listen_ref} =
        start_handshake_server!(hash, info_blob,
          mode: :serve,
          piece1_total_size: metadata_size + 999
        )

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:error, {:metadata_size_mismatch, bad, ^metadata_size}} =
               Magnet.Connection.fetch_metadata(peer, hash)

      assert bad == metadata_size + 999
    end
  end

  describe "Fetcher.fetch_metadata_round/3 swarm fallback" do
    setup do
      short_connected_env!()

      Application.put_env(:elixir_torrent, :magnet_fetcher, metadata_peer_timeout_ms: 3_000)

      :ok
    end

    test "falls back to direct TCP when swarm has no metadata peers" do
      {_, info_blob, hash} = build_info_blob!(name: "round-fallback")
      {port, _listen_ref} = start_handshake_server!(hash, info_blob, mode: :serve)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      magnet = %Magnet{hash: hash, trackers: [], x_pe_peers: [peer], display_name: "fb"}
      path = Magnet.Fetcher.torrent_path(hash)

      on_exit(fn ->
        File.rm(path)
        Magnet.Bootstrap.stop(hash)
      end)

      assert {:ok, ^path, [], false} = Magnet.Fetcher.fetch_metadata_round(magnet, [peer], [])
      assert File.read!(path) == Magnet.build_torrent!(magnet, info_blob)
    end

    test "merges unavailable errors when swarm is empty and direct TCP rejects" do
      {_, info_blob, hash} = build_info_blob!(name: "round-merge")
      {port, _listen_ref} = start_handshake_server!(hash, info_blob, mode: :reject)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}
      magnet = %Magnet{hash: hash, trackers: [], x_pe_peers: [peer], display_name: "merge"}

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      assert {:error, {:metadata_unavailable, [:metadata_unavailable]}} =
               Magnet.Fetcher.fetch_metadata_round(magnet, [peer], [])
    end
  end

  describe "Fetcher helpers" do
    test "run returns already_fetching when registry holds a session pid" do
      hash = <<40::160>>
      parent = self()

      magnet = %Magnet{
        hash: hash,
        trackers: [],
        x_pe_peers: [%Peer{ip: {127, 0, 0, 1}, port: 1}],
        display_name: nil
      }

      ref = make_ref()

      holder =
        spawn(fn ->
          assert {:ok, _} = Registry.register(Registry, {:magnet_fetch, hash}, ref)
          send(parent, {:holder_ready, self()})

          receive do
            :stop -> Registry.unregister(Registry, {:magnet_fetch, hash})
          end
        end)

      on_exit(fn -> send(holder, :stop) end)

      assert_receive {:holder_ready, ^holder}, @timeout
      assert Magnet.Fetcher.fetch_session_active?(hash)
      assert {:error, {:already_fetching, ^holder}} = Magnet.Fetcher.run(magnet, self())
    end

    test "await returns timeout immediately when no result message" do
      ref = make_ref()
      assert {:error, :timeout} = Magnet.Fetcher.await(ref, 0)
    end

    test "a non-retryable piece error is returned, not raised" do
      # The per-peer reducer halts with a plain `{:error, reason}` as soon as a
      # failure is not worth asking the next peer about; the accumulator it
      # otherwise carries is a 3-tuple. `finalize_piece_attempt/1` only matched
      # the accumulator, so every such error raised FunctionClauseError and took
      # the whole magnet fetch down instead of failing it.
      #
      # `:no_ut_metadata` reaches it without a socket: the peer's BEP 10
      # handshake never advertised `ut_metadata`, so there is no extension id to
      # send a request on. On Windows the same clause was reached far more often
      # through `:econnreset`, which is how a dropped peer reports there while
      # macOS reports the retryable `:closed`.
      conn = %Magnet.Connection{
        socket: nil,
        peer: %Peer{ip: {127, 0, 0, 1}, port: 1},
        hash: <<41::160>>,
        ltep: Session.new(),
        metadata_size: 256
      }

      assert {:error, :no_ut_metadata} = Magnet.Fetcher.download_pieces([conn], <<41::160>>)
    end

    test "a peer that resets mid-transfer is retryable, so the next peer is tried" do
      # `:econnreset`/`:econnaborted`/`:etimedout` are the Windows spellings of
      # the disconnect macOS reports as `:closed`/`:enotconn`/`:timeout`. Left
      # out of the retryable set, one rude peer aborted a fetch the rest of the
      # pool could have finished.
      for reason <- [:closed, :enotconn, :timeout, :econnreset, :econnaborted, :etimedout] do
        assert Magnet.Fetcher.retryable_piece_error_for_test?(reason),
               "expected #{inspect(reason)} to let the fetch move to the next peer"
      end

      refute Magnet.Fetcher.retryable_piece_error_for_test?(:no_ut_metadata)
      refute Magnet.Fetcher.retryable_piece_error_for_test?(:info_hash_mismatch)
    end
  end

  describe "Connection wire edge cases" do
    test "returns invalid_message when length prefix exceeds cap" do
      {client, server, listen} = loopback_pair!()

      spawn(fn ->
        :gen_tcp.send(server, <<0, 16, 0, 0, 0>>)
        :gen_tcp.close(server)
      end)

      conn = ut_metadata_conn(client, total_size: 50, unchoked?: true)
      assert {:error, reason} = Magnet.Connection.request_piece(conn, 0)
      assert reason in [:invalid_message, :timeout, :closed, :peer_died]

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end

    test "returns invalid_piece_size when declared total_size disagrees across pieces" do
      hash = :crypto.strong_rand_bytes(20)
      pad = 18_000

      info = %{
        "name" => "1234567890",
        "length" => pad + 50,
        "piece length" => 16_384,
        "pieces" => :binary.copy(<<0::160>>, 2),
        "pad" => :binary.copy(<<0>>, pad)
      }

      info_blob = Bento.encode!(info)
      metadata_size = byte_size(info_blob)

      {port, _listen_ref} =
        start_handshake_server!(hash, info_blob,
          mode: :serve,
          piece1_total_size: metadata_size + 500
        )

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:error, {:metadata_size_mismatch, bad, ^metadata_size}} =
               Magnet.Connection.fetch_metadata(peer, hash)

      assert bad == metadata_size + 500
    end

    test "fetch_metadata uses second peer when first dial fails" do
      {_, info_blob, hash} = build_info_blob!(name: "pool-fallback")
      {port, _} = start_handshake_server!(hash, info_blob, mode: :serve)
      good = %Peer{ip: {127, 0, 0, 1}, port: port}
      bad = %Peer{ip: {127, 0, 0, 1}, port: 1}
      magnet = %Magnet{hash: hash, trackers: [], display_name: "pool"}

      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      assert {:ok, _path, false} =
               Magnet.Fetcher.fetch_metadata_from_peer_for_test(magnet, bad, [bad, good])
    end
  end

  ## loopback helpers --------------------------------------------------------

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
      peer_timeout_ms: 3_000,
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
      "piece length" => 16_384,
      "pieces" => <<0::160>>
    }

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
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])
    {:ok, server} = :gen_tcp.accept(listen, @timeout)
    {client, server, listen}
  end

  defp ut_metadata_conn(client, opts) do
    total_size = Keyword.fetch!(opts, :total_size)
    unchoked? = Keyword.get(opts, :unchoked?, true)

    peer_hs = %Handshake{m: %{"ut_metadata" => @peer_ut_id}, metadata_size: total_size}

    ltep =
      Session.new([Magnet.UtMetadata.Extension])
      |> Session.apply_peer_handshake(peer_hs)

    %Magnet.Connection{
      socket: client,
      ltep: ltep,
      metadata_size: total_size,
      hash: Keyword.get(opts, :hash),
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

  defp start_handshake_server!(hash, info_blob, opts) do
    mode = Keyword.fetch!(opts, :mode)
    piece1_total_size = Keyword.get(opts, :piece1_total_size)
    parent = self()
    metadata_size = byte_size(info_blob)
    remote_id = <<50::160>>

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
              piece1_total_size
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
         piece1_total_size
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
      Bento.encode!(%{
        "m" => %{"ut_metadata" => @peer_ut_id},
        "metadata_size" => metadata_size
      })

    :ok = :gen_tcp.send(socket, Peer.LTEP.extended_message_wire(0, peer_hs))
    {:ok, <<0, 0, 0, 1, id>>} = :gen_tcp.recv(socket, 5, @timeout)
    true = id == Peer.Const.interested_id()
    :ok = :gen_tcp.send(socket, <<0, 0, 0, 1, Peer.Const.unchoke_id()>>)

    serve_metadata_requests(
      socket,
      metadata_serve_ctx(info_blob, metadata_size, mode, piece1_total_size)
    )
  catch
    _, _ -> :ok
  after
    :gen_tcp.close(socket)
  end

  defp metadata_serve_ctx(info_blob, total_size, mode, piece1_total_size) do
    %{
      info_blob: info_blob,
      total_size: total_size,
      mode: mode,
      piece1_total_size: piece1_total_size,
      served: %{}
    }
  end

  defp serve_metadata_requests(socket, ctx) do
    case recv_wire_frame(socket) do
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
        send_ut_reject(socket, piece)
        ctx

      :serve ->
        reply_total = metadata_reply_total(piece, ctx)
        size = Magnet.UtMetadata.piece_byte_size(reply_total, piece)
        data = metadata_piece_bytes(piece, size, ctx)
        send_ut_data(socket, piece, reply_total, data)
        %{ctx | served: Map.put(ctx.served, piece, true)}
    end
  end

  defp metadata_reply_total(piece, ctx) do
    if piece == 1 and is_integer(ctx.piece1_total_size),
      do: ctx.piece1_total_size,
      else: ctx.total_size
  end

  defp metadata_piece_bytes(piece, size, ctx) do
    if piece == 1 and is_integer(ctx.piece1_total_size) do
      :binary.copy(<<0xBB>>, size)
    else
      offset = piece * 16_384
      binary_part(ctx.info_blob, offset, size)
    end
  end

  defp recv_wire_frame(socket) do
    case :gen_tcp.recv(socket, 4, @timeout) do
      {:ok, <<0, 0, 0, 0>>} ->
        recv_wire_frame(socket)

      {:ok, <<len::32>>} when len >= 1 ->
        case :gen_tcp.recv(socket, len, @timeout) do
          {:ok, <<20, ext_id, payload::binary>>} when len >= 2 ->
            {:ok, {:extended, ext_id, payload}}

          {:ok, <<msg_id, rest::binary>>} ->
            {:ok, {:standard, msg_id, rest}}

          other ->
            other
        end

      other ->
        other
    end
  end
end

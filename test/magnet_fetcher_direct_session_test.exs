defmodule Magnet.FetcherDirectSessionTest do
  use ExUnit.Case, async: false

  alias Magnet.Fetcher.Session
  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension

  @timeout 2_000
  @block Magnet.UtMetadata.block_size()
  @local_ut_id UtMetadataExtension.local_id()
  @peer_ut_id 1
  @interested_id Peer.Const.interested_id()

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)

    previous_fetcher = Application.get_env(:elixir_torrent, :magnet_fetcher, [])
    previous_connection = Application.get_env(:elixir_torrent, :magnet_connection, [])
    previous_dht = Application.get_env(:elixir_torrent, :dht, [])
    previous_handler = Application.get_env(:elixir_torrent, :metadata_ok_handler)

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :magnet_fetcher, previous_fetcher)
      Application.put_env(:elixir_torrent, :magnet_connection, previous_connection)
      Application.put_env(:elixir_torrent, :dht, previous_dht)
      Application.put_env(:elixir_torrent, :metadata_ok_handler, previous_handler)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)

    Application.put_env(:elixir_torrent, :magnet_connection,
      unchoke_wait_ms: 50,
      unchoke_stable_ms: 0
    )

    :ok
  end

  describe "Fetcher.fetch_metadata_from_peer_for_test/3 direct TCP path" do
    test "downloads multi-piece metadata, verifies hash, and writes .torrent" do
      {info_map, info_blob, hash} = build_multi_piece_info_blob!(pad_bytes: 18_000)
      metadata_size = byte_size(info_blob)
      assert metadata_size > @block
      assert Magnet.UtMetadata.piece_count(metadata_size) == 2

      magnet = %Magnet{
        hash: hash,
        trackers: [],
        display_name: "multi"
      }

      path = Magnet.Fetcher.torrent_path(hash)
      on_exit(fn -> File.rm(path) end)

      {port, server_ref} = start_tcp_metadata_server!(info_blob, hash, mode: :serve)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:ok, ^path, false} =
               Magnet.Fetcher.fetch_metadata_from_peer_for_test(magnet, peer, [peer])

      assert_receive {:metadata_pieces_served, ^server_ref, pieces}, @timeout
      assert Map.keys(pieces) |> Enum.sort() == [0, 1]
      assert File.read!(path) == Magnet.build_torrent!(magnet, info_blob)

      assert {:ok, decoded, ^info_blob} =
               Magnet.UtMetadata.decode_and_verify_info(info_blob, hash)

      assert decoded["name"] == info_map["name"]
    end

    test "download_pieces/2 with no connections fails fast" do
      hash = :crypto.strong_rand_bytes(20)

      assert {:error, :metadata_unavailable} = Magnet.Fetcher.download_pieces([], hash)
    end

    test "fetch_metadata_round/3 with no peers returns no_peers" do
      magnet = %Magnet{hash: <<1::160>>, trackers: [], x_pe_peers: [], display_name: "none"}

      assert {:error, :no_peers} = Magnet.Fetcher.fetch_metadata_round(magnet, [], [])
    end

    test "returns info_hash_mismatch when wire blob does not match magnet hash" do
      {info_map, info_blob, hash} = build_multi_piece_info_blob!(pad_bytes: 18_000)
      wrong_blob = Bento.encode!(Map.put(info_map, "name", "wrong-piece-name-xx"))
      assert byte_size(wrong_blob) == byte_size(info_blob)

      magnet = %Magnet{hash: hash, trackers: [], display_name: "bad-hash"}
      {port, _server_ref} = start_tcp_metadata_server!(wrong_blob, hash, mode: :serve)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:error, :info_hash_mismatch} =
               Magnet.Fetcher.fetch_metadata_from_peer_for_test(magnet, peer, [peer])
    end

    test "returns metadata_unavailable when peer rejects every piece" do
      {_, info_blob, hash} = build_multi_piece_info_blob!(pad_bytes: 18_000)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "reject"}
      {port, _server_ref} = start_tcp_metadata_server!(info_blob, hash, mode: :reject)
      peer = %Peer{ip: {127, 0, 0, 1}, port: port}

      assert {:error, :metadata_unavailable} =
               Magnet.Fetcher.fetch_metadata_from_peer_for_test(magnet, peer, [peer])
    end
  end

  describe "Fetcher.Session handle_info/2 unit paths" do
    setup do
      Application.put_env(:elixir_torrent, :magnet_fetcher,
        max_fetch_lifetime_ms: 86_400_000,
        round_backoff_base_ms: 30_000
      )

      on_exit(fn -> flush_mailbox() end)
      :ok
    end

    test "round_result success notifies caller, runs metadata_ok_handler, and stops" do
      {_, info_blob, hash} = build_multi_piece_info_blob!(pad_bytes: 100)
      ref = make_ref()
      path = Magnet.Fetcher.torrent_path(hash)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Magnet.build_torrent!(session_magnet(hash), info_blob))
      on_exit(fn -> File.rm(path) end)

      test_pid = self()

      Application.put_env(:elixir_torrent, :metadata_ok_handler, fn mag, written_path ->
        send(test_pid, {:metadata_ok_handler, mag.hash, written_path})
        :ok
      end)

      state = base_state(hash: hash, ref: ref, round: 1)

      assert {:stop, :normal, _} =
               Session.handle_info({:round_result, {:ok, path, [], false}}, state)

      assert_receive {:magnet_fetch, ^ref, {:ok, ^path}}, @timeout
      assert_receive {:metadata_ok_handler, ^hash, ^path}, @timeout
    end

    test "round_result error schedules retry timer with backoff" do
      ref = make_ref()
      state = base_state(hash: <<21::160>>, ref: ref, round: 1)

      assert {:noreply, new_state} =
               Session.handle_info(
                 {:round_result, {:error, {:metadata_unavailable, [:timeout]}}},
                 state
               )

      assert is_reference(new_state.round_timer)
      assert Process.read_timer(new_state.round_timer) > 0
      assert Process.cancel_timer(new_state.round_timer) > 0
      assert Process.read_timer(new_state.round_timer) == false
      refute_receive {:magnet_fetch, ^ref, _}, 0
    end

    test "round_worker DOWN enqueues round_worker_crashed retry" do
      worker =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      mon_ref = make_ref()

      state =
        base_state(hash: <<22::160>>, round: 1)
        |> Map.put(:round_worker, {worker, mon_ref})

      Process.exit(worker, :abnormal)

      assert {:noreply, mid_state} =
               Session.handle_info({:DOWN, mon_ref, :process, worker, :abnormal}, state)

      assert mid_state.round_worker == nil
      assert_receive {:round_result, {:error, :round_worker_crashed}}, @timeout

      assert {:noreply, final_state} =
               Session.handle_info({:round_result, {:error, :round_worker_crashed}}, mid_state)

      assert is_reference(final_state.round_timer)
      assert Process.read_timer(final_state.round_timer) > 0
      assert Process.cancel_timer(final_state.round_timer) > 0
      assert Process.read_timer(final_state.round_timer) == false
    end

    test "upgrade_magnet merges trackers, cancels pending round timer, and queues run_round" do
      hash = <<23::160>>
      timer = Process.send_after(self(), :run_round, 600_000)

      state =
        base_state(
          hash: hash,
          magnet: session_magnet(hash, trackers: ["http://first.invalid/announce"]),
          round_timer: timer,
          round: 1
        )

      incoming = %Magnet{
        hash: hash,
        trackers: ["http://second.invalid/announce", "http://third.invalid/announce"],
        x_pe_peers: [],
        display_name: "upgrade-in"
      }

      assert {:noreply, new_state} = Session.handle_info({:upgrade_magnet, incoming}, state)
      assert Process.read_timer(timer) == false
      assert new_state.round_timer == nil
      assert length(new_state.magnet.trackers) == 3
      assert_receive :run_round, @timeout
    end

    test "expired :run_round stops with timeout result" do
      Application.put_env(:elixir_torrent, :magnet_fetcher, max_fetch_lifetime_ms: 1)
      ref = make_ref()

      state =
        base_state(
          hash: <<24::160>>,
          ref: ref,
          round: 1,
          started_at_ms: System.monotonic_time(:millisecond) - 10_000
        )

      assert {:stop, :normal, _} = Session.handle_info(:run_round, state)
      assert_receive {:magnet_fetch, ^ref, {:error, :timeout}}, @timeout
    end

    test "cancel kills round worker, cancels timer, and notifies cancelled" do
      ref = make_ref()
      timer = Process.send_after(self(), :run_round, 600_000)

      worker =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state =
        base_state(hash: <<25::160>>, ref: ref, round: 1)
        |> Map.put(:round_timer, timer)
        |> Map.put(:round_worker, {worker, make_ref()})

      assert {:stop, :normal, _} = Session.handle_info(:cancel, state)
      assert Process.read_timer(timer) == false
      assert_receive {:magnet_fetch, ^ref, {:error, :cancelled}}, @timeout
      refute Process.alive?(worker)
    end

    test "terminate/2 cancels timer and unregisters from Registry" do
      hash = <<26::160>>
      ref = make_ref()
      {:ok, _} = Registry.register(Registry, {:magnet_fetch, hash}, ref)
      timer = Process.send_after(self(), :run_round, 600_000)

      state =
        base_state(hash: hash, ref: ref)
        |> Map.put(:round_timer, timer)

      assert :ok = Session.terminate(:normal, state)
      assert Process.read_timer(timer) == false
      assert Registry.lookup(Registry, {:magnet_fetch, hash}) == []
    end
  end

  ## direct TCP metadata server ----------------------------------------------

  defp build_multi_piece_info_blob!(opts) do
    pad_bytes = Keyword.fetch!(opts, :pad_bytes)

    info = %{
      "name" => "fetcher-multi-piece",
      "length" => pad_bytes + 100,
      "piece length" => @block,
      "pieces" => :binary.copy(<<0::160>>, 2),
      "pad" => :binary.copy(<<0xAB>>, pad_bytes)
    }

    blob = Bento.encode!(info)
    {info, blob, :crypto.hash(:sha, blob)}
  end

  defp start_tcp_metadata_server!(info_blob, hash, opts) do
    mode = Keyword.fetch!(opts, :mode)
    parent = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    remote_id = <<30::160>>

    spawn(fn ->
      send(parent, {:metadata_server_listen, self()})

      try do
        case :gen_tcp.accept(listen, @timeout) do
          {:ok, socket} ->
            serve_direct_metadata(parent, self(), socket, hash, remote_id, info_blob, mode)

          {:error, _} ->
            :ok
        end
      after
        :gen_tcp.close(listen)
      end
    end)

    assert_receive {:metadata_server_listen, server_pid}, @timeout
    {port, server_pid}
  end

  defp serve_direct_metadata(test_pid, server_ref, socket, hash, remote_id, info_blob, mode) do
    metadata_size = byte_size(info_blob)

    try do
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
      :ok = recv_interested(socket)
      :ok = :gen_tcp.send(socket, <<0, 0, 0, 1, Peer.Const.unchoke_id()>>)

      pieces =
        ut_metadata_loop(
          test_pid,
          server_ref,
          socket,
          info_blob,
          metadata_size,
          mode,
          %{}
        )

      if mode == :serve, do: send(test_pid, {:metadata_pieces_served, server_ref, pieces})
    catch
      _, _ -> :ok
    after
      :gen_tcp.close(socket)
    end
  end

  defp recv_interested(socket) do
    case :gen_tcp.recv(socket, 5, @timeout) do
      {:ok, <<0, 0, 0, 1, id>>} when id == @interested_id -> :ok
      other -> other
    end
  end

  defp ut_metadata_loop(test_pid, server_ref, socket, info_blob, total_size, mode, pieces) do
    case recv_wire_frame(socket) do
      {:ok, {:extended, @peer_ut_id, payload}} ->
        handle_metadata_request(
          test_pid,
          server_ref,
          socket,
          info_blob,
          total_size,
          mode,
          payload,
          pieces
        )

      _ ->
        pieces
    end
  end

  defp handle_metadata_request(
         test_pid,
         server_ref,
         socket,
         info_blob,
         total_size,
         mode,
         payload,
         pieces
       ) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: piece]}} ->
        case mode do
          :serve ->
            send_metadata_piece(socket, info_blob, total_size, piece)

            ut_metadata_loop(
              test_pid,
              server_ref,
              socket,
              info_blob,
              total_size,
              mode,
              Map.put(pieces, piece, true)
            )

          :reject ->
            reject =
              Peer.LTEP.extended_message_wire(
                @local_ut_id,
                Magnet.UtMetadata.encode_reject(piece)
              )

            :ok = :gen_tcp.send(socket, reject)

            ut_metadata_loop(
              test_pid,
              server_ref,
              socket,
              info_blob,
              total_size,
              mode,
              pieces
            )
        end

      _ ->
        ut_metadata_loop(test_pid, server_ref, socket, info_blob, total_size, mode, pieces)
    end
  end

  defp send_metadata_piece(socket, info_blob, total_size, piece) do
    offset = piece * @block
    size = Magnet.UtMetadata.piece_byte_size(total_size, piece)
    data = binary_part(info_blob, offset, size)

    wire =
      Peer.LTEP.extended_message_wire(
        @local_ut_id,
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

          {:ok, <<msg_id, rest::binary>>} ->
            {:ok, {:standard, msg_id, rest}}

          other ->
            other
        end

      other ->
        other
    end
  end

  ## Session unit helpers ----------------------------------------------------

  defp session_magnet(hash, opts \\ []) do
    %Magnet{
      hash: hash,
      trackers: Keyword.get(opts, :trackers, []),
      x_pe_peers: Keyword.get(opts, :x_pe_peers, [%Peer{ip: {127, 0, 0, 1}, port: 9}]),
      display_name: "session"
    }
  end

  defp base_state(opts) do
    hash = Keyword.fetch!(opts, :hash)
    ref = Keyword.get(opts, :ref, make_ref())

    %{
      magnet: Keyword.get(opts, :magnet, session_magnet(hash)),
      caller: Keyword.get(opts, :caller, self()),
      ref: ref,
      stats: [
        uploaded: 0,
        downloaded: 0,
        left: Magnet.metadata_left(),
        event: Torrent.started()
      ],
      round: Keyword.get(opts, :round, 0),
      known_peers: %{},
      peer_attempts: %{},
      announced_trackers: [],
      round_timer: Keyword.get(opts, :round_timer, nil),
      round_worker: Keyword.get(opts, :round_worker, nil),
      started_at_ms: Keyword.get(opts, :started_at_ms, System.monotonic_time(:millisecond))
    }
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end

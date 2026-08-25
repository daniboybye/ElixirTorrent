defmodule PeerControllerCoverageBatchTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Peer.HashWire
  alias Peer.LTEP.Session
  alias Peer.UtPex.Entry, as: UtPexEntry
  alias Peer.UtPex.Extension, as: UtPexExtension
  alias PeerWireTest.SentCollector
  alias Torrent.Downloads.Piece

  @piece_len 16_384
  @block_len 4_096
  @timeout 2_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "public API catch exits on dead controller" do
    test "interested_sync, stale_useless_pin?, eviction_info, and metadata queries return safe defaults" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<11::160>>
      key = Peer.make_key(hash, id)

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, ctrl} = start_controller(hash, id)
        TestSupport.Sync.safe_stop(ctrl, 500)

        assert Peer.Controller.interested_sync(key, 0) == :ok
        assert Peer.Controller.stale_useless_pin?(key)
        assert Peer.Controller.eviction_info(key) == :error
        assert Peer.Controller.metadata_session(key) == :error
        assert Peer.Controller.ltep_session(key) == :error
        assert Peer.Controller.holepunch_relay_info(key) == :error
        assert Peer.Controller.metadata_capable(key) == :error
        assert Peer.Controller.pex_entry(key) == :error
        refute Peer.Controller.peer_v2_support?(key)
        assert Peer.Controller.set_connection_origin(key, :outbound) == :ok
      end)
    end

    test "request_hashes returns noproc when controller is gone" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<12::160>>
      key = Peer.make_key(hash, id)
      req = sample_hash_request()

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, ctrl} = start_controller(hash, id)
        TestSupport.Sync.safe_stop(ctrl, 500)

        assert {:error, :noproc} = Peer.Controller.request_hashes(key, req)
      end)
    end
  end

  describe "public cast and query callbacks on live controller" do
    test "have, superseed_assign, choke, unchoke, and reset_rank route through GenServer" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, <<20::160>>, fn key, ctrl ->
          assert :ok = Peer.Controller.have(key, 1)
          assert :ok = Peer.Controller.superseed_assign(key, 2)
          assert :ok = Peer.Controller.reset_rank(key)
          TestSupport.Sync.sync(ctrl)

          state = controller_state(key)
          assert state.superseed_piece == 2

          {hash_part, id} = key
          assert :ok = Peer.Controller.unchoke(hash_part, id)
          assert :ok = Peer.Controller.choke(hash_part, id)
          TestSupport.Sync.sync(ctrl)
          assert controller_state(key).choke
        end)
      end)
    end

    test "seed cast on loopback socket transitions to seeder and emits have batch" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<20::160>>
      {listen, server, _client} = listen_socket()
      on_exit(fn -> close_quietly(listen) end)
      on_exit(fn -> close_quietly(server) end)

      with_model(sample_torrent(hash, 4), fn _ ->
        key = Peer.make_key(hash, id)
        {:ok, _} = SentCollector.start_link(key, self())

        {:ok, ctrl} =
          GenServer.start(
            Peer.Controller,
            [hash, id, server, Peer.reserved()],
            name: controller_via(key)
          )

        on_exit(fn -> stop_quietly(ctrl) end)

        assert :ok = Peer.Controller.seed(key)
        TestSupport.Sync.sync(ctrl)
        assert controller_state(key).status == :seed
        assert_receive {:sent, {:have, _}}, @timeout
      end)
    end

    test "cancel cast clears a matching in-flight download request" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<21::160>>

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, id, fn key, ctrl ->
          request = {0, 0, @piece_len}

          replace_controller_state(key, fn state ->
            %{state | requests: MapSet.new([request])}
          end)

          assert :ok = Peer.Controller.cancel(hash, id, 0, 0, @piece_len)
          TestSupport.Sync.sync(ctrl)

          assert MapSet.size(controller_state(key).requests) == 0
        end)
      end)
    end

    test "peer_v2_support?, pex_entry, and set_connection_origin reflect controller state" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<22::160>>
      {listen, server, client} = listen_socket()

      on_exit(fn ->
        close_quietly(listen)
        close_quietly(server)
        close_quietly(client)
      end)

      with_model(sample_torrent(hash, 4), fn _ ->
        key = Peer.make_key(hash, id)
        {:ok, _} = SentCollector.start_link(key, self())

        {:ok, ctrl} =
          GenServer.start(
            Peer.Controller,
            [hash, id, server, Peer.reserved()],
            name: controller_via(key)
          )

        on_exit(fn -> stop_quietly(ctrl) end)

        assert Peer.Controller.peer_v2_support?(key) == Peer.v2_support?(Peer.reserved())

        assert {:ok, entry} = Peer.Controller.pex_entry(key)
        assert elem(UtPexEntry.endpoint(entry), 0) == {127, 0, 0, 1}

        assert :ok = Peer.Controller.set_connection_origin(key, :inbound)
        TestSupport.Sync.sync(ctrl)
        assert controller_state(key).connection_origin == :inbound
      end)
    end

    test "send_pex and send_pex_snapshot casts reach Sender stub" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, <<23::160>>, fn key, ctrl ->
          payload = Bento.encode!(%{"added" => <<>>})

          replace_controller_state(key, fn state ->
            %{state | ltep: ltep_with_ut_pex()}
          end)

          assert :ok = Peer.Controller.send_pex(key, payload)
          assert_receive {:sent, {:socket_raw, _wire}}, @timeout

          snapshot = %{{{1, 2, 3, 4}, 6881} => UtPexEntry.new({{1, 2, 3, 4}, 6881})}
          assert :ok = Peer.Controller.send_pex_snapshot(key, snapshot)
          TestSupport.Sync.sync(ctrl)
        end)
      end)
    end
  end

  describe "handle_piece validation and successful block delivery" do
    test "valid block forwards to piece worker; invalid shapes stop with protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<24::160>>
      key = Peer.make_key(hash, id)
      block = :crypto.strong_rand_bytes(@block_len)

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, piece_pid} = Piece.start_link(hash, 0)
        on_exit(fn -> stop_quietly(piece_pid) end)

        with_controller(hash, id, fn ctrl ->
          request = {0, 0, @block_len}

          replace_controller_state(key, fn state ->
            %{
              state
              | status: 0,
                requests: MapSet.new([request]),
                interested: true,
                choke_me: false
            }
          end)

          assert :ok = Peer.Controller.handle_piece(key, 0, 0, block)
          TestSupport.Sync.sync(ctrl)

          state = controller_state(key)
          assert MapSet.size(state.requests) == 0
          assert state.downloaded_bytes == @block_len

          for {index, begin_at, payload} <- [
                {99, 0, block},
                {0, @piece_len - 1, block},
                {0, 0, :crypto.strong_rand_bytes(@piece_len + 1)}
              ] do
            bad_id = :crypto.strong_rand_bytes(20)
            {:ok, bad_ctrl} = start_controller(hash, bad_id)
            bad_key = Peer.make_key(hash, bad_id)
            ref = Process.monitor(bad_ctrl)

            if index == 0 and begin_at == 0 and byte_size(payload) > @piece_len do
              replace_controller_state(bad_key, fn s ->
                %{s | requests: MapSet.new([{0, 0, byte_size(payload)}])}
              end)
            end

            Peer.Controller.handle_piece(bad_key, index, begin_at, payload)

            assert_receive {:DOWN, ^ref, :process, ^bad_ctrl, {:shutdown, :protocol_error}},
                           @timeout
          end

          assert Process.alive?(ctrl)
        end)
      end)
    end
  end

  describe "request_hashes and hash_request_timeout GenServer paths" do
    test "request_hashes rejects non-v2 peers and hash_request_timeout notifies caller" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<25::160>>
      req = sample_hash_request()
      reserved_no_v2 = clear_v2_bit(Peer.reserved())
      test_pid = self()

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, id, reserved_no_v2, fn key, _ctrl ->
          refute Peer.v2_support?(reserved_no_v2)
          assert {:error, :peer_not_v2} = Peer.Controller.request_hashes(key, req)

          ref = make_ref()
          key_tuple = Peer.HashTransfer.request_key(req)
          timer = Process.send_after(test_pid, {:hash_timeout_done, ref}, 999_999)
          on_exit(fn -> Process.cancel_timer(timer) end)
          pending = %{ref: ref, request: req, caller: test_pid, timer: timer}

          state =
            controller_state(key)
            |> Map.put(:peer_v2_support?, true)
            |> Map.put(:hash_requests, %{key_tuple => pending})

          assert {:noreply, _} =
                   Peer.Controller.handle_info({:hash_request_timeout, ref}, state)

          assert_receive {:peer_hash_transfer, ^ref, {:timeout, ^req}}, @timeout

          assert {:noreply, ^state} =
                   Peer.Controller.handle_info({:hash_request_timeout, make_ref()}, state)
        end)
      end)
    end

    test "request_hashes returns validation error without v2 disk context" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<26::160>>
      req = sample_hash_request()

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, id, fn key, _ctrl ->
          assert {:error, :missing_v2_context} = Peer.Controller.request_hashes(key, req)
        end)
      end)
    end
  end

  describe "handle_info/2 exit propagation and complete_upload call" do
    test "normal linked EXIT is ignored; abnormal EXIT stops the controller" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, <<27::160>>, fn _key, ctrl ->
          send(ctrl, {:EXIT, self(), :normal})
          TestSupport.Sync.sync(ctrl)
          assert Process.alive?(ctrl)

          ref = Process.monitor(ctrl)
          send(ctrl, {:EXIT, self(), :kill})
          assert_receive {:DOWN, ^ref, :process, ^ctrl, :kill}, @timeout
        end)
      end)
    end

    test "complete_upload call serves queued upload through GenServer" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<28::160>>
      block = :crypto.strong_rand_bytes(@block_len)

      with_tmp_dir(fn dir ->
        piece_data = :crypto.strong_rand_bytes(@piece_len)
        torrent = build_single_piece_torrent(hash, dir, piece_data: piece_data)

        with_upload_stack(torrent, piece_data, fn _ ->
          with_controller_and_sender(hash, id, fn key, ctrl ->
            replace_controller_state(key, fn state ->
              %{
                state
                | choke: false,
                  status: :seed,
                  upload_requests: MapSet.new([{0, 0, @block_len}])
              }
            end)

            assert :sent =
                     GenServer.call(
                       controller_via(key),
                       {:complete_upload, 0, 0, @block_len, block},
                       @timeout
                     )

            assert_receive {:sent, {:piece, 0, 0, ^block}}, @timeout
            TestSupport.Sync.sync(ctrl)
            assert MapSet.size(controller_state(key).upload_requests) == 0
          end)
        end)
      end)
    end
  end

  describe "start_protocol startup and duplicate peer guard" do
    test "start_protocol on leech sends interested, unchoke, bitfield, LTEP, and optional DHT port" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<29::160>>
      {listen, server, _client} = listen_socket()
      on_exit(fn -> close_quietly(listen) end)
      on_exit(fn -> close_quietly(server) end)

      with_model(sample_torrent(hash, 4), fn _ ->
        key = Peer.make_key(hash, id)
        {:ok, _} = SentCollector.start_link(key, self())

        {:ok, ctrl} =
          GenServer.start(
            Peer.Controller,
            [hash, id, server, Peer.reserved()],
            name: controller_via(key)
          )

        on_exit(fn -> stop_quietly(ctrl) end)

        log =
          capture_log(fn ->
            assert :ok = Peer.Controller.start_protocol(key)
          end)

        assert_receive {:sent, :interested}, @timeout
        assert_receive {:sent, :unchoke}, @timeout
        assert_receive {:sent, {:bitfield, ^hash}}, @timeout
        assert_receive {:sent, {:socket_raw, _ltep_hs}}, @timeout

        if DHT.enabled?() and is_integer(DHT.port()) do
          assert_receive {:sent, {:port, _}}, @timeout
        end

        if log =~ "[ltep]" do
          assert log =~ Torrent.hex_encoded_hash(hash)
        end
      end)
    end

    test "start_protocol on metadata bootstrap leech skips bitfield and only unchokes for metadata" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<30::160>>
      magnet = %Magnet{hash: hash, trackers: [], display_name: "controller-startup-md"}

      :ok = Magnet.Bootstrap.ensure(magnet)
      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      with_metadata_bootstrap(magnet, metadata_stub_torrent(hash), fn _ ->
        with_controller_and_sender(hash, id, fn key, _ctrl ->
          assert :ok = Peer.Controller.start_protocol(key)
          assert_receive {:sent, :interested}, @timeout
          assert_receive {:sent, :unchoke}, @timeout
          refute_received {:sent, {:bitfield, _}}
        end)
      end)
    end

    test "start_protocol on completed seed with Fast sends allowed_fast after startup" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<31::160>>
      pieces = 12
      {listen, server, _client} = listen_socket()
      on_exit(fn -> close_quietly(listen) end)
      on_exit(fn -> close_quietly(server) end)

      with_model(sample_torrent(hash, pieces, left: 0, peer_status: :seed), fn _ ->
        key = Peer.make_key(hash, id)
        {:ok, _} = SentCollector.start_link(key, self())

        {:ok, ctrl} =
          GenServer.start(
            Peer.Controller,
            [hash, id, server, Peer.reserved()],
            name: controller_via(key)
          )

        on_exit(fn -> stop_quietly(ctrl) end)

        assert :ok = Peer.Controller.start_protocol(key)
        assert_receive {:sent, {:allowed_fast, _idx}}, @timeout
      end)
    end

    test "duplicate peer id at a second endpoint stops start_protocol with :duplicate_peer" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<32::160>>
      {listen, server, _} = listen_socket()
      on_exit(fn -> close_quietly(listen) end)
      on_exit(fn -> close_quietly(server) end)

      {:ok, holder} = Agent.start_link(fn -> :ok end)
      on_exit(fn -> stop_quietly(holder) end)
      assert :ok = Peer.Endpoints.claim_peer_id(hash, id, {10, 0, 0, 9}, 7777, holder)

      with_model(sample_torrent(hash, 4), fn _ ->
        key = Peer.make_key(hash, id)
        {:ok, _} = SentCollector.start_link(key, self())

        {:ok, ctrl} =
          GenServer.start(
            Peer.Controller,
            [hash, id, server, Peer.reserved()],
            name: controller_via(key)
          )

        ref = Process.monitor(ctrl)
        assert {:error, :duplicate_peer} = Peer.Controller.start_protocol(key)
        assert_receive {:DOWN, ^ref, :process, ^ctrl, {:shutdown, :duplicate_peer}}, @timeout
      end)
    end
  end

  describe "disconnect, terminate, and productive endpoint bookkeeping" do
    test "disconnect with custom reason closes loopback socket and stops with that reason" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<33::160>>
      {listen, server, client} = listen_socket()

      on_exit(fn ->
        close_quietly(listen)
        close_quietly(client)
      end)

      with_model(sample_torrent(hash, 4), fn _ ->
        key = Peer.make_key(hash, id)
        {:ok, _} = SentCollector.start_link(key, self())

        {:ok, ctrl} =
          GenServer.start(
            Peer.Controller,
            [hash, id, server, Peer.reserved()],
            name: controller_via(key)
          )

        ref = Process.monitor(ctrl)
        assert :ok = Peer.Controller.disconnect(key, {:shutdown, :manual_test})
        assert_receive {:DOWN, ^ref, :process, ^ctrl, {:shutdown, :manual_test}}, @timeout

        assert match?({:error, _}, :gen_tcp.recv(client, 1, 0)) or
                 match?({:ok, <<>>}, :gen_tcp.recv(client, 0, 0))
      end)
    end

    test "terminate logs unexpected disconnect reasons but stays quiet for swarm-cap shutdown" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, <<34::160>>, fn key, _ctrl ->
          log =
            capture_log(fn ->
              GenServer.stop(controller_via(key), :timeout, :infinity)
            end)

          assert log =~ "[peer_upload]"
          assert log =~ "disconnect reason=:timeout"

          {:ok, quiet_ctrl} = start_controller(hash, <<35::160>>)

          quiet_log =
            capture_log(fn ->
              try do
                GenServer.stop(quiet_ctrl, {:shutdown, :swarm_cap}, :infinity)
              catch
                :exit, _ -> :ok
              end
            end)

          refute quiet_log =~ "[peer_upload]"
        end)
      end)
    end

    @tag race_group: :peer_productive_redial
    test "terminate after productive download marks endpoint and offers redial on loopback socket" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<36::160>>
      {listen, server, _client} = listen_socket()
      on_exit(fn -> close_quietly(listen) end)

      with_model(sample_torrent(hash, 4), fn _ ->
        key = Peer.make_key(hash, id)
        {:ok, _} = SentCollector.start_link(key, self())

        {:ok, _ctrl} =
          GenServer.start(
            Peer.Controller,
            [hash, id, server, Peer.reserved()],
            name: controller_via(key)
          )

        replace_controller_state(key, fn state ->
          %{state | downloaded_bytes: @block_len}
        end)

        log =
          capture_log(fn ->
            try do
              GenServer.stop(controller_via(key), :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end)

        assert log =~ "[peer_dial]"
        assert log =~ "warm_redial"
      end)
    end
  end

  describe "Fast-extension guards and bootstrap leniency" do
    test "advisory Fast messages are ignored, not punished, when Fast was not negotiated" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<37::160>>
      key = Peer.make_key(hash, id)
      reserved_no_fast = reserved_without_fast()

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, ctrl} = start_controller(hash, id, reserved_no_fast)

        # Dropping the peer here also blacklists its id for every torrent, which
        # is far past what an advisory message deserves.
        assert :ok = Peer.Controller.handle_suggest_piece(key, 0)
        assert :ok = Peer.Controller.handle_allowed_fast(key, 0)
        assert :ok = Peer.Controller.handle_reject(key, 0, 0, 16_384)
        TestSupport.Sync.sync(ctrl)

        assert Process.alive?(ctrl)
        refute Acceptor.BlackList.member?(id)
        stop_quietly(ctrl)
      end)
    end

    test "have_all still counts when Fast was not negotiated" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<47::160>>
      key = Peer.make_key(hash, id)
      reserved_no_fast = reserved_without_fast()

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, ctrl} = start_controller(hash, id, reserved_no_fast)

        # It says exactly what a full bitfield says, so there is nothing to gain
        # from discarding it — and a seeder we record as having nothing is a
        # connection we can never request from.
        assert :ok = Peer.Controller.handle_have_all(key)
        TestSupport.Sync.sync(ctrl)

        assert Process.alive?(ctrl)
        assert :sys.get_state(ctrl).bitfield == :all
        stop_quietly(ctrl)
      end)
    end

    test "non-negotiated Fast messages are ignored during magnet bootstrap" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<38::160>>
      key = Peer.make_key(hash, id)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "controller-fast-bootstrap"}
      reserved_no_fast = reserved_without_fast()

      :ok = Magnet.Bootstrap.ensure(magnet)
      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      with_metadata_bootstrap(magnet, metadata_stub_torrent(hash), fn _ ->
        {:ok, ctrl} = start_controller(hash, id, reserved_no_fast)

        assert :ok = Peer.Controller.handle_allowed_fast(key, 0)
        assert :ok = Peer.Controller.handle_have_all(key)
        TestSupport.Sync.sync(ctrl)
        assert Process.alive?(ctrl)
        stop_quietly(ctrl)
      end)
    end
  end

  describe "PEX initial snapshot handle_info" do
    test "pex_initial_snapshot schedules apply when outbound PEX is pending" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, <<39::160>>, fn key, _ctrl ->
          state =
            replace_controller_state(key, fn s ->
              %{
                s
                | ltep: ltep_with_ut_pex(),
                  pex_outbound: %{
                    initial_sent?: false,
                    initial_pending?: true,
                    sent: %{}
                  }
              }
            end)

          assert {:noreply, ^state} = Peer.Controller.handle_info(:pex_initial_snapshot, state)
        end)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count, opts \\ []) do
    left = Keyword.get(opts, :left, pieces_count * @piece_len)

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => @piece_len}},
      left: left,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(pieces_count),
      peer_status: Keyword.get(opts, :peer_status, nil)
    }
  end

  defp metadata_stub_torrent(hash) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "md-stub", "piece length" => @piece_len}},
      left: @piece_len,
      last_index: 0,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(1),
      peer_status: nil
    }
  end

  defp sample_hash_request do
    %HashWire{
      pieces_root: :crypto.strong_rand_bytes(32),
      base_layer: 0,
      index: 0,
      length: 1,
      proof_layers: 0
    }
  end

  defp clear_v2_bit(reserved) do
    <<prefix::59, _v2::1, suffix::4>> = reserved
    <<prefix::59, 0::1, suffix::4>>
  end

  defp reserved_without_fast do
    <<0, 0, 0, 0, 0, 0x10, 0, 0x11>>
  end

  defp with_metadata_bootstrap(_magnet, torrent, fun) do
    case Torrent.Model.start_link(torrent) do
      {:ok, model_pid} ->
        on_exit(fn -> stop_quietly(model_pid) end)

      {:error, {:already_started, _model_pid}} ->
        :ok
    end

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp with_model(torrent, fun) do
    case Torrent.Model.start_link(torrent) do
      {:ok, model_pid} ->
        on_exit(fn -> stop_quietly(model_pid) end)

      {:error, {:already_started, model_pid}} ->
        on_exit(fn -> stop_quietly(model_pid) end)
    end

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp start_controller(hash, id, reserved \\ Peer.reserved()) do
    key = Peer.make_key(hash, id)

    pid =
      case GenServer.start(
             Peer.Controller,
             [hash, id, nil, reserved],
             name: controller_via(key)
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn -> stop_quietly(pid) end)
    {:ok, pid}
  end

  defp with_controller(hash, id, fun) do
    {:ok, ctrl} = start_controller(hash, id)
    fun.(ctrl)
  end

  defp with_controller_and_sender(hash, id, fun),
    do: with_controller_and_sender(hash, id, Peer.reserved(), fun)

  defp with_controller_and_sender(hash, id, reserved, fun) do
    key = Peer.make_key(hash, id)
    {:ok, _} = SentCollector.start_link(key, self())

    {:ok, ctrl} = start_controller(hash, id, reserved)
    fun.(key, ctrl)
  end

  defp controller_via(key), do: {:via, Registry, {Registry, {key, Peer.Controller}}}

  defp controller_state(key), do: :sys.get_state(controller_via(key))

  defp replace_controller_state(key, fun) when is_function(fun, 1) do
    :sys.replace_state(controller_via(key), fun)
  end

  defp ltep_with_ut_pex do
    alias Peer.LTEP.Handshake

    Session.new([UtPexExtension])
    |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_pex" => 2}}))
  end

  defp listen_socket do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {ip, port}} = :inet.sockname(listen)
    {:ok, client} = :gen_tcp.connect(ip, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listen)
    {listen, server, client}
  end

  defp with_tmp_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "et_peer_cov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    fun.(dir)
  end

  defp build_single_piece_torrent(hash, download_dir, opts) do
    piece_data = Keyword.get(opts, :piece_data, :crypto.strong_rand_bytes(@piece_len))
    pieces_hash = :crypto.hash(:sha, piece_data)

    info = %{
      "name" => "seed.bin",
      "length" => @piece_len,
      "piece length" => @piece_len,
      "pieces" => pieces_hash
    }

    bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(1), 0, 1)

    %Torrent{
      hash: hash,
      metadata: %{"info" => info},
      left: 0,
      downloaded: @piece_len,
      last_index: 0,
      last_piece_length: @piece_len,
      bitfield: bitfield,
      download_dir: download_dir,
      peer_status: :seed
    }
  end

  defp with_upload_stack(torrent, piece_data, fun) do
    with_model(torrent, fn _ ->
      {:ok, fh_pid} = Torrent.FileHandle.start_link(torrent.hash)
      on_exit(fn -> stop_quietly(fh_pid) end)

      case Task.Supervisor.start_link(
             max_restarts: 0,
             name: {:via, Registry, {Registry, {torrent.hash, Torrent.Uploader}}}
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      seed_piece_on_disk!(torrent.hash, 0, piece_data)
      fun.(torrent)
    end)
  end

  defp seed_piece_on_disk!(hash, index, data) do
    :ok = Torrent.FileHandle.write(hash, index, 0, data)
    :ok = Torrent.FileHandle.flush(hash, index)
    :ok = Torrent.PiecesStatistic.set(hash, index, :complete)
  end

  defp stop_quietly(pid) do
    if is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
  end

  defp close_quietly(port) do
    if is_port(port) do
      try do
        :gen_tcp.close(port)
      catch
        :error, _ -> :ok
      end
    end
  end
end

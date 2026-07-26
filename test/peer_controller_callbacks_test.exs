defmodule PeerControllerCallbacksTest do
  use ExUnit.Case, async: false

  alias PeerWireTest.SentCollector

  @piece_len 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "public Controller callbacks (deterministic lifecycle)" do
    test "handle_choke/unchoke/interested casts update controller state" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller(hash, fn key ->
          assert :ok = Peer.Controller.handle_unchoke(key)
          drain_cast()

          assert :ok = Peer.Controller.handle_interested(key)
          drain_cast()

          assert :ok = Peer.Controller.handle_choke(key)
          drain_cast()

          state = controller_state(key)
          assert state.choke_me

          assert :ok = Peer.Controller.handle_not_interested(key)
          drain_cast()
          refute controller_state(key).interested_of_me
        end)
      end)
    end

    test "rank, has_index?, has_all?, download_piece queries" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 1, 1)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller(hash, fn key ->
          :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
            %{state | bitfield: bf, status: 2, rank: 100, interested_of_me: true}
          end)

          assert Peer.Controller.rank(key) == {100, elem(key, 0)}
          assert Peer.Controller.has_index?(key, 1)
          refute Peer.Controller.has_index?(key, 0)
          refute Peer.Controller.has_all?(key)
          assert Peer.Controller.download_piece(key) == 2
        end)
      end)
    end

    test "disconnect sends wire operations via Sender stub and stops" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller_and_sender(hash, fn key, ctrl_pid ->
          ref = Process.monitor(ctrl_pid)

          :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
            %{
              state
              | interested: true,
                choke: false,
                requests: MapSet.new([{0, 0, @piece_len}])
            }
          end)

          assert :ok = Peer.Controller.disconnect(key)

          assert_receive {:send_operations, ops}, 2_000
          assert {:cancel, 0, 0, @piece_len} in ops
          assert :not_interested in ops
          assert :choke in ops

          assert_receive {:DOWN, ^ref, :process, ^ctrl_pid, :normal}, 2_000
        end)
      end)
    end

    test "metadata_session and ltep_session without LTEP return :error" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller(hash, fn key ->
          assert Peer.Controller.metadata_session(key) == :error
          assert Peer.Controller.ltep_session(key) == :error
          assert Peer.Controller.metadata_capable(key) == :error
        end)
      end)
    end

    test "fast-extension wire without negotiation stops with protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<4::160>>
      key = Peer.make_key(hash, id)

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, ctrl_pid} = start_controller(hash, id)

        ref = Process.monitor(ctrl_pid)
        assert :ok = Peer.Controller.handle_reject(key, 0, 0, @piece_len)

        assert_receive {:DOWN, ^ref, :process, ^ctrl_pid, {:shutdown, :protocol_error}}, 2_000
      end)
    end

    test "handle_piece with invalid block stops controller" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<4::160>>
      key = Peer.make_key(hash, id)

      with_model(sample_torrent(hash, 1), fn _ ->
        {:ok, ctrl_pid} = start_controller(hash, id)

        ref = Process.monitor(ctrl_pid)
        Peer.Controller.handle_piece(key, 0, 0, <<>>)

        assert_receive {:DOWN, ^ref, :process, ^ctrl_pid, {:shutdown, :protocol_error}}, 2_000
      end)
    end

    test "interested_sync repins and clears stale request slots" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller(hash, fn key ->
          :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
            %{
              state
              | status: 0,
                requests: MapSet.new([{0, 0, @piece_len}]),
                pending_requests: 2
            }
          end)

          assert :ok = Peer.Controller.interested_sync(key, 2)

          state = controller_state(key)
          assert state.status == 2
          assert MapSet.size(state.requests) == 0
          assert state.pending_requests == 0
        end)
      end)
    end

    test "stale_useless_pin? and eviction_info via public API" do
      hash = :crypto.strong_rand_bytes(20)
      now = System.monotonic_time(:millisecond)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_controller(hash, fn key ->
          :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
            %{
              state
              | status: 0,
                choke_me: true,
                pin_downloaded_bytes: 0,
                pinned_at: now - 30_000,
                connected_at: now - 30_000,
                last_block_at: now - 30_000
            }
          end)

          assert Peer.Controller.stale_useless_pin?(key)

          info = Peer.Controller.eviction_info(key)
          assert info.downloaded_bytes == 0
          assert info.idle_ms >= 30_000
        end)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => @piece_len}},
      left: pieces_count * @piece_len,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(pieces_count),
      peer_status: nil
    }
  end

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      stop_quietly(model_pid)
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp start_controller(hash, id) do
    key = Peer.make_key(hash, id)

    pid =
      case GenServer.start(
             Peer.Controller,
             [hash, id, nil, Peer.reserved()],
             name: {:via, Registry, {Registry, {key, Peer.Controller}}}
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn -> stop_quietly(pid) end)
    {:ok, pid}
  end

  defp with_controller(hash, fun) do
    id = <<4::160>>
    {:ok, _pid} = start_controller(hash, id)
    fun.(Peer.make_key(hash, id))
  end

  defp with_controller_and_sender(hash, fun) do
    id = <<5::160>>
    key = Peer.make_key(hash, id)

    {:ok, _sender} = SentCollector.start_link(key, self())

    pid =
      case GenServer.start(
             Peer.Controller,
             [hash, id, nil, Peer.reserved()],
             name: {:via, Registry, {Registry, {key, Peer.Controller}}}
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn ->
      stop_quietly(pid)
      stop_quietly(GenServer.whereis({:via, Registry, {Registry, {key, Peer.Sender}}}))
    end)

    fun.(key, pid)
  end

  defp controller_state(key) do
    :sys.get_state({:via, Registry, {Registry, {key, Peer.Controller}}})
  end

  defp drain_cast do
    receive do
      _ -> drain_cast()
    after
      0 -> :ok
    end
  end

  defp stop_quietly(pid) do
    if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
  catch
    :exit, _ -> :ok
  end
end

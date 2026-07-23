defmodule PeerRequestPipelineTest do
  # Regression: stale in-flight wire requests on repin / timeout / worker death
  # saturate full_requests_queue?/1 → unchoked peers deliver 0 B/s.
  use ExUnit.Case, async: false

  alias Peer.Controller.State, as: PeerState
  alias Torrent.Downloads.Piece.{Request, State}

  @piece_len 16_384
  @peer_a <<11::160>>
  @peer_b <<22::160>>

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "repin clears stale controller request slots" do
    test "interested/2 on index change clears requests MapSet and pending_requests" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      with_model(torrent, fn _ ->
        state =
          base_peer_state(hash)
          |> Map.put(:status, 0)
          |> Map.put(:requests, MapSet.new([{0, 0, @piece_len}, {0, @piece_len, @piece_len}]))
          |> Map.put(:pending_requests, 3)

        new_state = PeerState.interested(state, 2)

        assert new_state.status == 2
        assert MapSet.size(new_state.requests) == 0
        assert new_state.pending_requests == 0
      end)
    end

    test "interested/2 same index does not clear in-flight requests" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      with_model(torrent, fn _ ->
        requests = MapSet.new([{1, 0, @piece_len}])

        state =
          base_peer_state(hash)
          |> Map.put(:status, 1)
          |> Map.put(:requests, requests)
          |> Map.put(:pending_requests, 2)

        new_state = PeerState.interested(state, 1)

        assert new_state.status == 1
        assert new_state.requests == requests
        assert new_state.pending_requests == 2
      end)
    end
  end

  describe "piece timeout/reject syncs peer controller accounting" do
    test "State.timeout/2 releases peer controller request slot" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)
      key = Peer.make_key(hash, @peer_a)

      with_model(torrent, fn _ ->
        {:ok, _pid} = start_mock_controller(hash, @peer_a)

        :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
          %{
            state
            | status: 0,
              requests: MapSet.new([{0, 0, @piece_len}]),
              interested: true,
              choke_me: false
          }
        end)

        piece_state =
          State.make({hash, 0})
          |> State.download(fn -> :ok end, fn -> :ok end)
          |> Map.put(:waiting, [{@piece_len, @piece_len}])
          |> Map.put(:requests, [
            %Request{peer_id: @peer_a, subpiece: {0, @piece_len}, timer: nil}
          ])

        _ = State.timeout(piece_state, @peer_a)
        assert_eventually(fn -> controller_requests(key) == MapSet.new() end)
      end)
    end

    test "State.reject/4 releases peer controller request slot" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)
      key = Peer.make_key(hash, @peer_a)

      with_model(torrent, fn _ ->
        {:ok, _pid} = start_mock_controller(hash, @peer_a)

        :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
          %{
            state
            | status: 0,
              requests: MapSet.new([{0, 0, @piece_len}]),
              interested: true,
              choke_me: false
          }
        end)

        piece_state =
          State.make({hash, 0})
          |> State.download(fn -> :ok end, fn -> :ok end)
          |> Map.put(:waiting, [])
          |> Map.put(:requests, [
            %Request{peer_id: @peer_a, subpiece: {0, @piece_len}, timer: nil}
          ])

        _ = State.reject(piece_state, @peer_a, 0, @piece_len)
        assert_eventually(fn -> controller_requests(key) == MapSet.new() end)
      end)
    end
  end

  describe "piece worker teardown releases peer request slots" do
    test "abnormal terminate clears in-flight requests on peer controller" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)
      key = Peer.make_key(hash, @peer_b)

      with_model(torrent, fn _ ->
        {:ok, ctrl_pid} = start_mock_controller(hash, @peer_b)

        :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
          %{
            state
            | status: 1,
              requests: MapSet.new([{1, 0, @piece_len}]),
              interested: true,
              choke_me: false
          }
        end)

        {:ok, piece_pid} = GenServer.start(Torrent.Downloads.Piece, {hash, 1})

        Torrent.Downloads.Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)

        :sys.replace_state(piece_pid, fn state ->
          %{
            state
            | requests: [
                %Request{peer_id: @peer_b, subpiece: {0, @piece_len}, timer: nil}
              ],
              waiting: [{@piece_len, @piece_len}]
          }
        end)

        ref = Process.monitor(piece_pid)
        GenServer.stop(piece_pid, {:shutdown, :wrong_subpiece})

        assert_receive {:DOWN, ^ref, :process, ^piece_pid, {:shutdown, :wrong_subpiece}}, 500
        assert_eventually(fn -> controller_requests(key) == MapSet.new() end)
        assert Process.alive?(ctrl_pid)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count) do
    bitfield = Torrent.Bitfield.make(pieces_count)

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => @piece_len}},
      left: pieces_count * @piece_len,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: bitfield,
      peer_status: nil
    }
  end

  defp base_peer_state(hash) do
    struct!(PeerState, %{
      hash: hash,
      id: Peer.id(),
      fast_extension: nil,
      status: nil,
      pieces_count: 4,
      socket: nil
    })
  end

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      try do
        if Process.alive?(model_pid), do: GenServer.stop(model_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp start_mock_controller(hash, id) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    GenServer.start_link(
      Peer.Controller,
      [hash, id, nil, Peer.reserved()],
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  defp controller_requests(key) do
    :sys.get_state({:via, Registry, {Registry, {key, Peer.Controller}}}).requests
  end

  defp assert_eventually(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
      else
        flunk("condition not met: #{inspect(fun)}")
      end
    end
  end
end

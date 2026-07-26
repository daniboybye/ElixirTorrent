defmodule PeerRequestPipelineTest do
  # Regression: stale in-flight wire requests on repin / timeout / worker death
  # saturate full_requests_queue?/1 → unchoked peers deliver 0 B/s.
  use ExUnit.Case, async: false

  alias Peer.Controller.State, as: PeerState
  alias Torrent.Downloads
  alias Torrent.Downloads.Piece
  alias Torrent.Downloads.Piece.{Request, State}

  @moduletag race_group: :pipeline

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

  describe "Downloads.request/4 ack prevents pending_requests inflation" do
    test ":noop when piece worker has waiting=[] — does not inflate controller pending" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        peer_pid = ensure_peer_registered(hash, @peer_a)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)

        on_exit(fn -> stop_piece(piece_pid) end)

        :sys.replace_state(piece_pid, fn state ->
          %{state | waiting: [], requests: []}
        end)

        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 0)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)

        after_unchoke = PeerState.handle_unchoke(state)

        assert after_unchoke.pending_requests == 0
        assert MapSet.size(after_unchoke.requests) == 0
        cleanup_workers(piece_pid, peer_pid)
      end)
    end

    test "handle_unchoke :ok ack increments pending before callback is applied" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        peer_pid = ensure_peer_registered(hash, @peer_a)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)
        on_exit(fn -> stop_piece(piece_pid) end)

        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 0)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)

        # Pure State call runs in this process. Piece worker callback casts to
        # self() but GenServer semantics (N/A here) / process mailbox ordering
        # guarantees we inspect returned state before any cast is handled.
        after_unchoke = PeerState.handle_unchoke(state)

        assert after_unchoke.pending_requests == 1
        assert MapSet.size(after_unchoke.requests) == 0

        after_request = PeerState.request(after_unchoke, 0, 0, @piece_len)

        assert after_request.pending_requests == 0
        assert MapSet.size(after_request.requests) == 1
        drain_request_casts(1)
        cleanup_workers(piece_pid, peer_pid)
      end)
    end

    test "fill_request_pipeline stops on noop — drained unchoke does not loop to depth" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 1)
        peer_pid = ensure_peer_registered(hash, @peer_a)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)
        on_exit(fn -> stop_piece(piece_pid) end)

        :sys.replace_state(piece_pid, fn state ->
          %{state | waiting: [], requests: []}
        end)

        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 1)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)

        after_unchoke = PeerState.handle_unchoke(state)

        assert after_unchoke.pending_requests == 0
        assert MapSet.size(after_unchoke.requests) == 0
        assert after_unchoke.status == 1
        cleanup_workers(piece_pid, peer_pid)
      end)
    end

    test "fill_request_pipeline fills to reqq cap then stops on noop" do
      hash = :crypto.strong_rand_bytes(20)
      reqq = 3
      # 4 subpieces per piece index → pipeline can accept 3 :ok acks then noop.
      torrent = sample_torrent(hash, 3, 4 * @piece_len)

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        peer_pid = ensure_peer_registered(hash, @peer_a)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)
        on_exit(fn -> stop_piece(piece_pid) end)

        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 0)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)
          |> Map.put(:ltep, %Peer.LTEP.Session{peer: %{reqq: reqq}})

        after_unchoke = PeerState.handle_unchoke(state)

        assert after_unchoke.pending_requests == reqq
        assert MapSet.size(after_unchoke.requests) == 0
        drain_request_casts(reqq)
        cleanup_workers(piece_pid, peer_pid)
      end)
    end

    test ":error when worker is dead — pending stays zero and queue is not saturated" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      with_model(torrent, fn _ ->
        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 99)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)
          |> Map.put(:ltep, %Peer.LTEP.Session{peer: %{reqq: 2}})

        after_unchoke = PeerState.handle_unchoke(state)

        assert after_unchoke.pending_requests == 0
        assert MapSet.size(after_unchoke.requests) == 0
        assert is_nil(after_unchoke.status)
      end)
    end

    test "endgame redundancy cap returns :noop — pending stays zero" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3, @piece_len, left: @piece_len)

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        peer_pid = ensure_peer_registered(hash, @peer_a)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)
        on_exit(fn -> stop_piece(piece_pid) end)

        capped_requests =
          for n <- 1..3 do
            %Request{
              peer_id: <<n::160>>,
              subpiece: {0, @piece_len},
              timer: nil
            }
          end

        :sys.replace_state(piece_pid, fn state ->
          %{
            state
            | mode: :endgame,
              waiting: [{0, @piece_len}],
              requests: capped_requests
          }
        end)

        assert :noop =
                 Downloads.request(hash, 0, @peer_a, fn _i, _b, _l ->
                   flunk("endgame redundancy cap must not invoke callback")
                 end)

        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 0)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)

        after_unchoke = PeerState.handle_unchoke(state)
        assert after_unchoke.pending_requests == 0
        assert MapSet.size(after_unchoke.requests) == 0
        cleanup_workers(piece_pid, peer_pid)
      end)
    end

    test "drained piece cannot false-saturate reqq guard across repeated unchokes" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)
      reqq = 2

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 1)
        peer_pid = ensure_peer_registered(hash, @peer_a)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)
        on_exit(fn -> stop_piece(piece_pid) end)

        :sys.replace_state(piece_pid, fn state ->
          %{state | waiting: [], requests: []}
        end)

        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 1)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)
          |> Map.put(:ltep, %Peer.LTEP.Session{peer: %{reqq: reqq}})

        after_many =
          Enum.reduce(1..(reqq + 3), state, fn _, st ->
            PeerState.handle_unchoke(%{st | choke_me: true})
            |> PeerState.handle_unchoke()
          end)

        assert after_many.pending_requests == 0
        assert MapSet.size(after_many.requests) == 0
        cleanup_workers(piece_pid, peer_pid)
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
        sync_controller_requests(key)
        assert controller_requests(key) == MapSet.new()
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
        sync_controller_requests(key)
        assert controller_requests(key) == MapSet.new()
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

        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)

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
        sync_controller_requests(key)
        assert controller_requests(key) == MapSet.new()
        assert Process.alive?(ctrl_pid)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count, piece_len \\ @piece_len, opts \\ []) do
    left = Keyword.get(opts, :left, pieces_count * piece_len)
    bitfield = Torrent.Bitfield.make(pieces_count)

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => piece_len}},
      left: left,
      last_index: pieces_count - 1,
      last_piece_length: piece_len,
      bitfield: bitfield,
      peer_status: nil
    }
  end

  defp base_peer_state(hash, id \\ Peer.id()) do
    struct!(PeerState, %{
      hash: hash,
      id: id,
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

  defp sync_controller_requests(key) do
    TestSupport.Sync.sync({:via, Registry, {Registry, {key, Peer.Controller}}})
  end

  defp drain_request_casts(count) when is_integer(count) and count >= 0 do
    for _ <- 1..count do
      assert_receive {:"$gen_cast", {:request, _}}, 5_000
    end

    :ok
  end

  defp start_piece_worker(hash, index) do
    name = {:via, Registry, {Registry, {{index, hash}, Torrent.Downloads.Piece}}}

    GenServer.start(Torrent.Downloads.Piece, {hash, index}, name: name)
  end

  defp ensure_peer_registered(hash, id) do
    key = Peer.make_key(hash, id)
    via = {:via, Registry, {Registry, {key, Peer}}}

    case GenServer.whereis(via) do
      nil ->
        {:ok, pid} = __MODULE__.DummyPeer.start_link(via)
        pid

      pid ->
        pid
    end
  end

  defp cleanup_workers(piece_pid, peer_pid) do
    stop_piece(piece_pid)
    if peer_pid, do: stop_piece(peer_pid)
  end

  defp stop_piece(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end
end

defmodule PeerRequestPipelineTest.DummyPeer do
  @moduledoc false
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl true
  def init(_), do: {:ok, nil}
end

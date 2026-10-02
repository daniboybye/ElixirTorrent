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

  describe "request window follows the measured rate" do
    # Pieces here are 64 blocks and the torrent has 12 of them: Model switches to
    # endgame (where a block is NOT removed from `waiting` when handed out) once
    # <= 10 pieces remain, which would hide the quota behaviour under test.
    #
    # A fixed 64-block queue let the first peer that asked take a whole 1 MiB piece
    # whatever its speed. The window now covers ~3 s of the peer's own rate (its
    # bandwidth-delay product with slack), between 4 and 64 blocks.
    @mib 1_048_576

    test "an unmeasured peer starts small" do
      state = base_peer_state(:crypto.strong_rand_bytes(20))
      assert PeerState.request_window(state, 1_000) == 4
      assert PeerState.download_rate(state, 1_000) == 0
    end

    test "the window scales with rate and is capped at the old fixed depth" do
      now = 10_000
      at = fn rate -> rate_state(rate, now) end

      # 24 KB/s (the slow-seed case measured live) needs ~5 blocks, not 64.
      assert PeerState.request_window(at.(24_000), now) == 5
      # 100 KB/s: 300 KB of data in 3 s = 19 blocks.
      assert PeerState.request_window(at.(100_000), now) == 19
      # A fast peer keeps the full pipeline: nothing slower than before.
      assert PeerState.request_window(at.(@mib), now) == 64
      assert PeerState.request_window(at.(50 * @mib), now) == 64
    end

    test "the peer's own reqq still caps the window" do
      state = rate_state(@mib, 10_000)
      state = %{state | ltep: %Peer.LTEP.Session{peer: %{reqq: 10}}}
      assert PeerState.request_window(state, 10_000) == 10
    end

    test "a peer that goes quiet decays back to the minimum window" do
      state = rate_state(@mib, 10_000)
      assert PeerState.request_window(state, 10_000) == 64
      # Two empty buckets later nothing of the old rate is left.
      assert PeerState.download_rate(state, 10_000 + 2 * 2_000 + 1) == 0
      assert PeerState.request_window(state, 10_000 + 2 * 2_000 + 1) == 4
    end

    test "a stream of delivered blocks grows the window" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, 64 * @piece_len), fn _ ->
        blocks = for i <- 0..39, do: {0, i * @piece_len, @piece_len}

        state =
          base_peer_state(hash)
          |> Map.put(:status, 0)
          |> Map.put(:requests, MapSet.new(blocks))

        assert PeerState.request_window(state) == 4

        # 40 blocks = 640 KiB land well inside one 2 s bucket (~320 KB/s), which
        # is enough to want ~60 blocks in flight.
        grown =
          Enum.reduce(blocks, state, fn {i, b, l}, st -> PeerState.handle_piece(st, i, b, l) end)

        assert grown.downloaded_bytes == 40 * @piece_len
        assert PeerState.request_window(grown) > 40
      end)
    end

    test "a slow peer cannot take a whole piece; a fast one still can" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 12, 64 * @piece_len)

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        slow_peer = ensure_peer_registered(hash, @peer_a)
        fast_peer = ensure_peer_registered(hash, @peer_b)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)
        on_exit(fn -> stop_piece(piece_pid) end)

        pinned = fn id ->
          base_peer_state(hash, id)
          |> Map.put(:status, 0)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)
        end

        slow = PeerState.handle_unchoke(pinned.(@peer_a))
        assert slow.pending_requests == 4
        assert length(:sys.get_state(piece_pid).waiting) == 60

        # The fast peer arrives second and still finds the rest of the piece.
        fast_state = %{pinned.(@peer_b) | pace: pace(now_ms(), 4 * @mib)}
        fast = PeerState.handle_unchoke(fast_state)
        assert fast.pending_requests == 60
        assert :sys.get_state(piece_pid).waiting == []

        drain_request_casts(64)
        cleanup_workers(piece_pid, slow_peer)
        stop_piece(fast_peer)
      end)
    end
  end

  describe "a timed-out peer is not handed its blocks back" do
    test "cancel_timed_out leaves the peer one request, not its old window" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 12, 64 * @piece_len)

      with_model(torrent, fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        peer = ensure_peer_registered(hash, @peer_a)
        Piece.download(piece_pid, fn -> :ok end, fn -> :ok end)
        on_exit(fn -> stop_piece(piece_pid) end)

        held = for i <- 0..4, do: {0, i * @piece_len, @piece_len}
        # The piece worker no longer lists the five blocks the peer sat on: they
        # were re-queued by the timeout, which is the state cancel runs against.
        :sys.replace_state(piece_pid, fn st ->
          %{st | waiting: Enum.map(held, fn {_, b, l} -> {b, l} end) ++ st.waiting}
        end)

        state =
          base_peer_state(hash, @peer_a)
          |> Map.put(:status, 0)
          |> Map.put(:interested, true)
          |> Map.put(:choke_me, false)
          |> Map.put(:requests, MapSet.new(held))
          # A good rate: without the penalty this peer would refill to 64.
          |> Map.put(:pace, pace(now_ms(), 4 * @mib))

        penalised =
          Enum.reduce(held, state, fn {i, b, l}, st ->
            PeerState.cancel_timed_out(st, i, b, l)
          end)

        assert penalised.pace.penalty
        assert MapSet.size(penalised.requests) == 0
        assert penalised.pending_requests == 1
        assert PeerState.request_window(penalised) == 1

        # Contrast: an ordinary cancel (duplicate in endgame) refills the window.
        refilled =
          Enum.reduce(held, state, fn {i, b, l}, st -> PeerState.cancel(st, i, b, l) end)

        assert refilled.pending_requests > 1

        drain_request_casts(1 + refilled.pending_requests)
        cleanup_workers(piece_pid, peer)
      end)
    end

    test "the first block it delivers lifts the penalty" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_peer_state(hash)
        |> Map.put(:status, 0)
        |> Map.put(:pace, %{pace(nil, 0) | penalty: true})
        |> Map.put(:requests, MapSet.new([{0, 0, @piece_len}]))

      assert PeerState.request_window(state) == 1
      delivered = PeerState.handle_piece(state, 0, 0, @piece_len)
      refute delivered.pace.penalty
      assert PeerState.request_window(delivered) >= 4
    end

    test "Piece.State.timeout/2 tells the peer controller it was a timeout" do
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

        _ = State.timeout(piece_state, @peer_a)
        sync_controller_requests(key)

        assert :sys.get_state({:via, Registry, {Registry, {key, Peer.Controller}}}).pace.penalty
      end)
    end

    test "a peer's own reject is not a timeout and carries no penalty" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)
      key = Peer.make_key(hash, @peer_a)

      with_model(torrent, fn _ ->
        {:ok, _pid} = start_mock_controller(hash, @peer_a)

        piece_state =
          State.make({hash, 0})
          |> State.download(fn -> :ok end, fn -> :ok end)
          |> Map.put(:waiting, [])
          |> Map.put(:requests, [
            %Request{peer_id: @peer_a, subpiece: {0, @piece_len}, timer: nil}
          ])

        _ = State.reject(piece_state, @peer_a, 0, @piece_len)
        sync_controller_requests(key)

        refute :sys.get_state({:via, Registry, {Registry, {key, Peer.Controller}}}).pace.penalty
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

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A peer state whose rate estimator reads `rate` bytes/s at `now`: the whole
  # current bucket (2 s) holds rate * 2 bytes.
  defp rate_state(rate, now) do
    base_peer_state(:crypto.strong_rand_bytes(20))
    |> Map.put(:pace, pace(now, rate * 2))
  end

  defp pace(bucket_at, cur), do: %{bucket_at: bucket_at, cur: cur, prev: 0, penalty: false}

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(model_pid, 5_000)
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
    TestSupport.Sync.safe_stop(pid, 1_000)
  end
end

defmodule PeerRequestPipelineTest.DummyPeer do
  @moduledoc false
  use GenServer

  @spec start_link(GenServer.name()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl GenServer
  def init(_), do: {:ok, nil}
end

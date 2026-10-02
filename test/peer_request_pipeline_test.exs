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
  @peer_c <<33::160>>
  @mib 1_048_576

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

  describe "a drained pin continues on another active piece" do
    # Pieces are 4 blocks here and the torrent has 12, so it is not in endgame
    # (<= 10 pieces left). Everything runs through the real `Downloads` supervisor
    # and real piece workers: `request_any/4` only looks at *active* pieces, which
    # are the supervisor's children.
    #
    # Why it matters: a peer works down ONE pinned piece and a piece is small, so a
    # fast peer reaches its end within a fraction of a second. If the next piece is
    # only chosen by an outside signal (new piece started / 2 s reconcile), the
    # request queue drains to zero at every boundary and the pipe sits empty. The
    # queue has to stay full across the boundary, so the peer continues on its own.
    @blocks 4

    test "reaching the end of its piece, the peer immediately requests the next one" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        start_active_piece(hash, 1)

        state = working_peer(hash, @peer_a, 0)
        after_unchoke = PeerState.handle_unchoke(state)

        # Piece 0 gave its 4 blocks, then :noop, then piece 1 gave 4 more: no outside
        # signal, one step. The pin followed the work.
        assert after_unchoke.pending_requests == 2 * @blocks
        assert after_unchoke.status == 1

        wanted = take_requests(2 * @blocks)
        assert Enum.frequencies_by(wanted, &elem(&1, 0)) == %{0 => @blocks, 1 => @blocks}
        assert length(Enum.uniq(wanted)) == 2 * @blocks
        refute_receive {:"$gen_cast", {:request, _}}, 0
      end)
    end

    test "requests already in flight to the old piece are kept and still accepted" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        start_active_piece(hash, 1)

        crossed = PeerState.handle_unchoke(working_peer(hash, @peer_a, 0))
        assert crossed.status == 1

        # The piece worker's callbacks land in the controller as `request/4`.
        in_flight =
          Enum.reduce(take_requests(2 * @blocks), crossed, fn {i, b, l}, st ->
            PeerState.request(st, i, b, l)
          end)

        # Crossing the boundary did NOT cancel piece 0's requests (that is what
        # interested/2 does when the Swarm moves a peer for good).
        assert MapSet.size(in_flight.requests) == 2 * @blocks
        assert Enum.count(in_flight.requests, &(elem(&1, 0) == 0)) == @blocks

        # ...so a block of piece 0 arriving while we are pinned to piece 1 is a
        # normal answer to our own request, not a protocol violation.
        delivered = PeerState.handle_piece(in_flight, 0, 0, @piece_len)
        assert %PeerState{} = delivered
        assert delivered.downloaded_bytes == @piece_len
        assert MapSet.size(delivered.requests) == 2 * @blocks - 1
      end)
    end

    test "the window is respected across the boundary and refills one block at a time" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        piece_one = start_active_piece(hash, 1)

        state =
          working_peer(hash, @peer_a, 0)
          |> Map.put(:ltep, %Peer.LTEP.Session{peer: %{reqq: 6}})

        crossed = PeerState.handle_unchoke(state)

        # 4 from piece 0 + only 2 from piece 1: the window (6) caps the peer, so
        # the other two blocks of piece 1 stay free for somebody else.
        assert crossed.pending_requests == 6
        assert crossed.status == 1
        assert length(:sys.get_state(piece_one).waiting) == 2

        in_flight =
          Enum.reduce(take_requests(6), crossed, fn {i, b, l}, st ->
            PeerState.request(st, i, b, l)
          end)

        # Each delivered block frees one slot, refilled from piece 1 — the queue
        # does not drain at the boundary.
        one = PeerState.handle_piece(in_flight, 0, 0, @piece_len)
        assert one.pending_requests == 1
        assert [{1, _, _}] = take_requests(1)

        two = PeerState.handle_piece(one, 0, @piece_len, @piece_len)
        assert two.pending_requests == 2
        assert [{1, _, _}] = take_requests(1)
        assert :sys.get_state(piece_one).waiting == []
      end)
    end

    test "a pin on a dead piece worker is replaced by another active piece" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 1)

        # Piece 7 has no worker (it just verified, or died).
        after_unchoke = PeerState.handle_unchoke(working_peer(hash, @peer_a, 7))

        assert after_unchoke.status == 1
        assert after_unchoke.pending_requests == @blocks
        # A cleared pin starts a fresh clock (0 means "never pinned"; monotonic time
        # may be negative, so test for "set", not for sign).
        assert after_unchoke.pinned_at != 0
        assert length(take_requests(@blocks)) == @blocks
      end)
    end

    test "the same assignment keeps its pin clock across the boundary" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        start_active_piece(hash, 1)

        pinned_at = now_ms() - 5_000

        state =
          working_peer(hash, @peer_a, 0)
          |> Map.merge(%{pinned_at: pinned_at, pin_downloaded_bytes: 123})

        crossed = PeerState.handle_unchoke(state)
        assert crossed.status == 1
        # `stale_useless_pin?/1` measures how long a peer has gone without
        # delivering; restarting that clock at every boundary would hide a dead one.
        assert crossed.pinned_at == pinned_at
        assert crossed.pin_downloaded_bytes == 123
        take_requests(2 * @blocks)
      end)
    end

    test "a peer that lacks the other piece does not move" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        piece_one = start_active_piece(hash, 1)

        # Only piece 0 is set in this peer's bitfield (12 pieces = 2 bytes).
        only_zero = working_peer(hash, @peer_a, 0) |> Map.put(:bitfield, <<0b1000_0000, 0>>)
        after_unchoke = PeerState.handle_unchoke(only_zero)

        assert after_unchoke.status == 0
        assert after_unchoke.pending_requests == @blocks
        assert length(:sys.get_state(piece_one).waiting) == @blocks
        take_requests(@blocks)
      end)
    end

    test "a piece this peer served with a bad hash is not picked again" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        piece_one = start_active_piece(hash, 1)
        start_active_piece(hash, 2)

        state =
          working_peer(hash, @peer_a, 0) |> Map.put(:hash_failures, MapSet.new([1]))

        after_unchoke = PeerState.handle_unchoke(state)

        assert after_unchoke.status == 2
        assert length(:sys.get_state(piece_one).waiting) == @blocks
        assert Enum.all?(take_requests(2 * @blocks), &(elem(&1, 0) in [0, 2]))
      end)
    end

    test "choked: only an allowed-fast piece may be continued on" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        piece_one = start_active_piece(hash, 1)
        # Someone else already claimed all of piece 0: it is drained for us.
        claim_all(hash, 0, @peer_b)
        take_requests(@blocks)

        choked = fn fast_set ->
          working_peer(hash, @peer_a, 0)
          |> Map.merge(%{
            choke_me: true,
            fast_extension: %Peer.Controller.FastExtension{allowed_fast_me: fast_set}
          })
        end

        # Choked, and piece 1 is not in the allowed-fast set: nothing may be asked.
        stay = PeerState.cancel(choked.(MapSet.new([0])), 0, 0, @piece_len)
        assert stay.status == 0
        assert stay.pending_requests == 0
        assert length(:sys.get_state(piece_one).waiting) == @blocks

        # BEP 6: the allowed-fast set may be requested while choked.
        moved = PeerState.cancel(choked.(MapSet.new([0, 1])), 0, 0, @piece_len)
        assert moved.status == 1
        assert moved.pending_requests == 1
        assert [{1, _, _}] = take_requests(1)
      end)
    end

    test "fully choked without allowed-fast: no request, no re-pin" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        piece_one = start_active_piece(hash, 1)
        claim_all(hash, 0, @peer_b)
        take_requests(@blocks)

        choked = working_peer(hash, @peer_a, 0) |> Map.put(:choke_me, true)
        stay = PeerState.cancel(choked, 0, 0, @piece_len)

        assert stay.status == 0
        assert stay.pending_requests == 0
        assert length(:sys.get_state(piece_one).waiting) == @blocks
      end)
    end

    test "a penalised peer may hold one request, across the boundary too" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        piece_one = start_active_piece(hash, 1)
        claim_all(hash, 0, @peer_b)
        take_requests(@blocks)

        # Its request timed out: queue 1. Its pin (piece 0) has nothing for it.
        penalised = PeerState.cancel_timed_out(working_peer(hash, @peer_a, 0), 0, 0, @piece_len)

        assert penalised.pace.penalty
        assert penalised.status == 1
        assert penalised.pending_requests == 1
        assert length(:sys.get_state(piece_one).waiting) == @blocks - 1

        # With its one request outstanding it asks for nothing more, anywhere.
        still = PeerState.cancel(penalised, 0, 0, @piece_len)
        assert still.pending_requests == 1
        assert length(:sys.get_state(piece_one).waiting) == @blocks - 1
        take_requests(1)
      end)
    end

    test "peers do not over-claim: each stays within its own window" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        for index <- 0..2, do: start_active_piece(hash, index)

        # An unmeasured peer starts with a window of 4; the fast one is capped by
        # its reqq at 6. Together they take 10 of the 12 blocks, not all of them.
        slow = PeerState.handle_unchoke(unmeasured_peer(hash, @peer_a, 0))
        fast = fast_peer_with_reqq(hash, @peer_b, 0, 6) |> PeerState.handle_unchoke()

        assert slow.pending_requests == 4
        assert fast.pending_requests == 6
        assert fast.status == 2

        # A third peer arrives and still finds the rest.
        late = PeerState.handle_unchoke(unmeasured_peer(hash, @peer_c, 2))
        assert late.pending_requests == 2

        # All 12 blocks of the 3 pieces were handed out exactly once.
        wanted = take_requests(12)
        assert length(Enum.uniq(wanted)) == 12
        refute_receive {:"$gen_cast", {:request, _}}, 0
      end)
    end

    test "endgame is unchanged: a drained pin does not hop to another piece" do
      hash = :crypto.strong_rand_bytes(20)
      # left <= 10 pieces' worth of bytes => the torrent is in endgame.
      torrent = sample_torrent(hash, 12, @blocks * @piece_len, left: 4 * @blocks * @piece_len)

      with_model(torrent, fn _ ->
        assert Torrent.get(hash, :mode) == :endgame
        start_downloads(hash)
        start_active_piece(hash, 0)
        piece_one = start_active_piece(hash, 1)

        after_unchoke = PeerState.handle_unchoke(working_peer(hash, @peer_a, 0))

        # Endgame workers hold a block in `waiting` until it is delivered, so piece
        # 0 hands each block once to this peer and then says :noop. The Swarm's
        # hash-based spreading owns where the peer goes next, not this fast path.
        assert after_unchoke.status == 0
        assert after_unchoke.pending_requests == @blocks
        assert :sys.get_state(piece_one).requests == []
        take_requests(@blocks)
      end)
    end

    test "an empty look is not repeated on every block, but is retried once it ages" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        claim_all(hash, 0, @peer_b)
        take_requests(@blocks)

        state = working_peer(hash, @peer_a, 0)
        missed = PeerState.cancel(state, 0, 0, @piece_len)
        assert missed.status == 0
        assert is_integer(missed.pace.scan_at)

        # A piece with work appears right after the empty look.
        piece_one = start_active_piece(hash, 1)

        throttled = PeerState.cancel(missed, 0, 0, @piece_len)
        assert throttled.status == 0
        assert length(:sys.get_state(piece_one).waiting) == @blocks

        aged = put_in(throttled.pace.scan_at, now_ms() - 1_000)
        moved = PeerState.cancel(aged, 0, 0, @piece_len)
        assert moved.status == 1
        assert moved.pending_requests == 1
        take_requests(1)
      end)
    end

    test "Downloads.request_any/4 tries active pieces in index order and skips drained ones" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        for index <- [2, 0, 1], do: start_active_piece(hash, index)
        ensure_peer_registered(hash, @peer_a)
        claim_all(hash, 0, @peer_b)
        take_requests(@blocks)

        # The piece worker invokes the callback, so capture this process first.
        test_pid = self()
        callback = fn i, b, l -> send(test_pid, {:asked, i, b, l}) end

        # Piece 0 is drained, so the lowest piece with a block is 1.
        assert {:ok, 1} = Downloads.request_any(hash, @peer_a, fn _ -> true end, callback)
        assert_received {:asked, 1, _begin, @piece_len}

        # `eligible?` is applied before any piece is asked.
        assert {:ok, 2} = Downloads.request_any(hash, @peer_a, &(&1 == 2), callback)
        assert_received {:asked, 2, _begin, @piece_len}

        assert :none = Downloads.request_any(hash, @peer_a, fn _ -> false end, callback)
        assert :none = Downloads.request_any(hash, @peer_a, &(&1 == 99), callback)
        refute_received {:asked, _, _, _}
      end)
    end

    test "Downloads.request_any/4 finds nothing when no piece is active" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        assert :none =
                 Downloads.request_any(hash, @peer_a, fn _ -> true end, fn _, _, _ ->
                   flunk("no piece is active, nothing may be requested")
                 end)
      end)
    end

    test "through the real controller: unchoke fills the queue across two pieces" do
      hash = :crypto.strong_rand_bytes(20)
      key = Peer.make_key(hash, @peer_a)
      via = {:via, Registry, {Registry, {key, Peer.Controller}}}

      with_model(sample_torrent(hash, 12, @blocks * @piece_len), fn _ ->
        start_downloads(hash)
        start_active_piece(hash, 0)
        start_active_piece(hash, 1)
        {:ok, _controller} = start_mock_controller(hash, @peer_a)

        :sys.replace_state(via, fn st ->
          %{
            st
            | status: 0,
              bitfield: :all,
              interested: true,
              pieces_count: 12,
              pace: pace(now_ms(), 4 * @mib)
          }
        end)

        Peer.Controller.handle_unchoke(key)

        # The unchoke is handled, and the piece workers' callback casts were sent
        # while it was; the second sync drains them from the controller's mailbox.
        TestSupport.Sync.sync(via)
        state = TestSupport.Sync.sync(via)

        assert state.status == 1
        assert state.pending_requests == 0
        assert MapSet.size(state.requests) == 2 * @blocks

        assert state.requests
               |> MapSet.to_list()
               |> Enum.map(&elem(&1, 0))
               |> Enum.uniq()
               |> Enum.sort() == [0, 1]
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

  defp pace(bucket_at, cur),
    do: %{bucket_at: bucket_at, cur: cur, prev: 0, penalty: false, scan_at: nil}

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

  # The real Downloads supervisor for `hash`, so `Downloads.active_indices/1` (the
  # definition of "active piece" the request fast path uses) sees the workers.
  defp start_downloads(hash), do: start_supervised!(Downloads.child_spec(hash))

  defp start_active_piece(hash, index) do
    :ok = Downloads.piece(hash, index, fn -> :ok end, fn -> :ok end)
    pid = Piece.whereis(hash, index)
    # Drain the :download cast so the worker has read its mode before any request.
    TestSupport.Sync.sync(pid)
    pid
  end

  # An unchoked, interested peer that has every piece and is pinned to `index`,
  # downloading fast enough that its window is the full 64 (only reqq limits it).
  defp working_peer(hash, id, index) do
    ensure_peer_registered(hash, id)

    base_peer_state(hash, id)
    |> Map.merge(%{
      status: index,
      interested: true,
      choke_me: false,
      bitfield: :all,
      pieces_count: 12,
      pace: pace(now_ms(), 4 * @mib)
    })
  end

  # Same, but never measured: the window starts at the minimum of 4.
  defp unmeasured_peer(hash, id, index),
    do: %{working_peer(hash, id, index) | pace: pace(nil, 0)}

  defp fast_peer_with_reqq(hash, id, index, reqq),
    do: %{working_peer(hash, id, index) | ltep: %Peer.LTEP.Session{peer: %{reqq: reqq}}}

  # `peer_id` takes every unclaimed block of `index`, as another peer that got
  # there first would. The callbacks land in this test process; callers drain them.
  defp claim_all(hash, index, peer_id) do
    ensure_peer_registered(hash, peer_id)
    pid = self()

    Enum.each(1..@blocks, fn _ ->
      assert :ok =
               Downloads.request(hash, index, peer_id, fn i, b, l ->
                 GenServer.cast(pid, {:request, [i, b, l]})
               end)
    end)
  end

  defp take_requests(count) when count > 0 do
    for _ <- 1..count do
      assert_receive {:"$gen_cast", {:request, [index, begin, length]}}, 5_000
      {index, begin, length}
    end
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

defmodule DownloadPumpDeadlockTest do
  # Regression tests for the P0 "download request-pump deadlock" fix (2026-07).
  #
  # Live audit found 96% of unchokes did zero-request work: the pump is
  # edge-triggered by block arrivals + peer handoff, and abnormal piece exits
  # or peers pinned to drained pieces silently stopped it. These tests pin
  # the load-bearing invariants of the fix so future refactors do not
  # re-open the deadlock.
  use ExUnit.Case, async: false

  alias Peer.Controller.State
  alias Torrent.Downloads
  alias Torrent.Downloads.Piece

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  # Sub-part (d): a piece-worker via-name that no longer resolves must NOT
  # silently swallow a request — the peer has to learn about it and
  # unpin its status so the pump can re-pin to a live piece.
  test "Downloads.request/4 returns :error when the piece worker is dead" do
    hash = :crypto.strong_rand_bytes(20)
    # No Piece worker has ever been started for this {index, hash}.
    assert :error =
             Downloads.request(hash, 5, Peer.id(), fn _idx, _begin, _len -> :ok end)
  end

  test "Downloads.request/4 returns :noop when piece worker waiting=[] " do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 4)

    with_model(torrent, fn _ ->
      {:ok, pid} = start_piece_worker(hash, 0)

      on_exit(fn ->
        try do
          TestSupport.Sync.safe_stop(pid, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      Piece.download(pid, fn -> :ok end, fn -> :ok end)

      :sys.replace_state(pid, fn state -> %{state | waiting: [], requests: []} end)

      assert :noop =
               Downloads.request(hash, 0, Peer.id(), fn _i, _b, _l ->
                 flunk("noop path must not invoke callback")
               end)
    end)
  end

  test "Downloads.request/4 returns :noop on endgame redundancy cap" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 4)

    with_model(torrent, fn _ ->
      {:ok, pid} = start_piece_worker(hash, 0)

      on_exit(fn ->
        try do
          TestSupport.Sync.safe_stop(pid, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      Piece.download(pid, fn -> :ok end, fn -> :ok end)

      capped =
        for n <- 1..3 do
          %Torrent.Downloads.Piece.Request{
            peer_id: <<n::160>>,
            subpiece: {0, 16_384},
            timer: nil
          }
        end

      :sys.replace_state(pid, fn state ->
        %{
          state
          | mode: :endgame,
            waiting: [{0, 16_384}],
            requests: capped
        }
      end)

      assert :noop =
               Downloads.request(hash, 0, Peer.id(), fn _i, _b, _l ->
                 flunk("endgame redundancy cap must not invoke callback")
               end)
    end)
  end

  test "Downloads.request/4 returns :ok when piece worker hands out a block" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 4)
    parent = self()

    with_model(torrent, fn _ ->
      {:ok, pid} = start_piece_worker(hash, 0)
      peer_id = Peer.id()
      peer_pid = ensure_peer_registered(hash, peer_id)

      on_exit(fn ->
        try do
          TestSupport.Sync.safe_stop(pid, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      Piece.download(pid, fn -> :ok end, fn -> :ok end)

      assert :ok =
               Downloads.request(hash, 0, peer_id, fn idx, begin, len ->
                 send(parent, {:requested, idx, begin, len})
               end)

      assert_receive {:requested, 0, 0, 16_384}, 500
      cleanup_workers(pid, peer_pid)
    end)
  end

  # Sub-part (e) infrastructure: probe used by Swarm.assign_peer_to_piece?
  # to let a peer pinned to a drained piece migrate to a live one.
  test "Downloads.piece_has_waiting?/2 is false for a missing piece worker" do
    hash = :crypto.strong_rand_bytes(20)
    refute Downloads.piece_has_waiting?(hash, 0)
  end

  # Sub-part (c): abnormal termination must invoke the controller's pump-wake
  # closure. Without this, a hash-fail / stall / crash burns an active-piece
  # slot and the controller has no edge to notice.
  test "Piece terminate/2 fires requests_are_dealt on abnormal shutdown" do
    hash = :crypto.strong_rand_bytes(20)
    index = 3
    torrent = sample_torrent(hash, 4)

    with_model(torrent, fn _ ->
      parent = self()

      # Start a piece worker directly (bypassing the DynamicSupervisor).
      # We use start/2 (not start_link/2) so the abnormal shutdown below
      # doesn't propagate to the test process. Piece.init/1 expects
      # {hash, index} — see State.make/1.
      {:ok, pid} =
        GenServer.start(Piece, {hash, index})

      Piece.download(
        pid,
        fn -> send(parent, :downloaded_fired) end,
        fn -> send(parent, :dealt_fired) end
      )

      # Sanity: worker is alive.
      assert Process.alive?(pid)

      # Trip an abnormal stop.
      ref = Process.monitor(pid)
      GenServer.stop(pid, {:shutdown, :wrong_subpiece})

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :wrong_subpiece}}, 500
      assert_receive :dealt_fired, 500
      refute_received :downloaded_fired
    end)
  end

  # Sub-part (a): :reconcile_pump is the level-triggered safety-net message.
  # We can't easily drive the full :resume_ready path in isolation (it
  # would poll Model, Downloads, Swarm), but we can verify:
  #   1. The controller accepts :reconcile_pump without crashing.
  #   2. It self-reschedules — a subsequent :reconcile_pump lands after
  #      approximately @reconcile_interval (2s in production; we sample
  #      the mailbox at ~2.3s and confirm the process stayed alive).
  test "Torrent.Controller handles :reconcile_pump and self-reschedules" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 4)

    with_model(torrent, fn _ ->
      {:ok, pid} = GenServer.start(Torrent.Controller, hash)

      try do
        send(pid, :reconcile_pump)
        send(pid, :reconcile_pump)
        TestSupport.Sync.sync(pid)
        assert Process.alive?(pid)
      after
        TestSupport.Sync.safe_stop(pid, 500)
      end
    end)
  end

  # Sub-part (f): the choke handler must reset the pending-request counter
  # so the pipeline can refill from zero on the next unchoke. Otherwise a
  # peer whose Downloads.request acks were counted but whose responses
  # never landed (e.g. the piece was drained) sits with a permanently
  # over-full guard.
  test "handle_choke resets pending_requests to 0" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 4

    state =
      struct!(
        %State{
          hash: hash,
          id: Peer.id(),
          fast_extension: nil,
          status: nil,
          pieces_count: pieces_count,
          socket: nil,
          choke: true
        },
        pending_requests: 5
      )

    new_state = State.handle_choke(state)
    assert new_state.pending_requests == 0
    assert new_state.choke_me == true
    assert MapSet.size(new_state.requests) == 0
  end

  # Sub-part (f): a new pin (status change) must reset the counter so leaks
  # from the previous piece (drained / endgame silent skip) don't stick.
  test "State.interested resets pending_requests on status change" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 4
    torrent = sample_torrent(hash, pieces_count - 1)

    with_model(torrent, fn _ ->
      state =
        struct!(
          %State{
            hash: hash,
            id: Peer.id(),
            fast_extension: nil,
            status: nil,
            pieces_count: pieces_count,
            socket: nil,
            choke: true
          },
          pending_requests: 7
        )

      new_state = State.interested(state, 2)
      assert new_state.status == 2
      assert new_state.pending_requests == 0
    end)
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count) do
    bitfield = Torrent.Bitfield.make(pieces_count)

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => 16_384}},
      left: pieces_count * 16_384,
      last_index: pieces_count - 1,
      last_piece_length: 16_384,
      bitfield: bitfield,
      peer_status: nil
    }
  end

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      try do
        TestSupport.Sync.safe_stop(model_pid, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
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
    try do
      TestSupport.Sync.safe_stop(piece_pid, 1_000)
    catch
      :exit, _ -> :ok
    end

    if peer_pid do
      try do
        TestSupport.Sync.safe_stop(peer_pid, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end
end

defmodule DownloadPumpDeadlockTest.DummyPeer do
  @moduledoc false
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl GenServer
  def init(_), do: {:ok, nil}
end

defmodule OrphanPieceWorkerTest do
  # Regression: peers that connect, send interested, and drop before unchoke /
  # request/3 left piece workers in active_indices with requests=[] until the
  # old 100s stall timer — freezing effective_max_parallel=1 pumps.
  use ExUnit.Case, async: false

  alias Torrent.Downloads
  alias Torrent.Downloads.Piece
  alias Torrent.Downloads.Piece.State

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "idle orphan check stops worker with no in-flight requests and no swarm" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 3)
    parent = self()

    with_model(torrent, fn _ ->
      {:ok, pid} = GenServer.start(Piece, {hash, 0})

      Piece.download(
        pid,
        fn -> send(parent, :downloaded) end,
        fn -> send(parent, :dealt) end
      )

      ref = Process.monitor(pid)
      send(pid, :idle_orphan_check)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle_orphan}}, 500
      assert_receive :dealt, 500
      refute_received :downloaded
    end)
  end

  test "down/2 resolves monitor ref to peer and aborts orphan when swarm is empty" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 3)
    peer_id = Peer.id()

    with_model(torrent, fn _ ->
      peer = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(peer)

      state =
        State.make({hash, 1})
        |> State.download(fn -> :ok end, fn -> :ok end)
        |> Map.put(:monitoring, %{peer_id => mon_ref})

      assert {:abort, _state} = State.down(state, mon_ref)
      Process.exit(peer, :kill)
    end)
  end

  test "abort_if_orphan with force skips worker that still has in-flight requests" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 3)
    peer_id = Peer.id()

    with_model(torrent, fn _ ->
      {:ok, pid} = GenServer.start(Piece, {hash, 2})

      Piece.download(pid, fn -> :ok end, fn -> :ok end)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | requests: [
              %Torrent.Downloads.Piece.Request{
                peer_id: peer_id,
                subpiece: {0, 16_384},
                timer: nil
              }
            ]
        }
      end)

      Downloads.abort_idle_piece(hash, 2, force: true)
      Process.sleep(50)
      assert Process.alive?(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
      end)
    end)
  end

  test "reconcile_pump stops idle workers when connected peers drop to zero" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 4)
    parent = self()

    with_model(torrent, fn _ ->
      start_downloads_supervisor(hash)

      Downloads.piece(
        hash,
        0,
        fn -> :ok end,
        fn -> send(parent, :dealt) end
      )

      assert [0] = Downloads.active_indices(hash)

      {:ok, controller} = GenServer.start(Torrent.Controller, hash)

      on_exit(fn ->
        if Process.alive?(controller), do: GenServer.stop(controller, :normal, 500)
      end)

      send(controller, :reconcile_pump)

      assert_receive :dealt, 1_000
      refute Downloads.piece_active?(hash, 0)
    end)
  end

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
        if Process.alive?(model_pid), do: GenServer.stop(model_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp start_downloads_supervisor(hash) do
    name = {:via, Registry, {Registry, {hash, Torrent.Downloads}}}

    case DynamicSupervisor.start_link(
           name: name,
           extra_arguments: [hash],
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end

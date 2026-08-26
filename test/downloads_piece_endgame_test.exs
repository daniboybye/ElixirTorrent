defmodule DownloadsPieceEndgameTest do
  use ExUnit.Case, async: false

  alias Torrent.Downloads.Piece.{Request, State}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "endgame accepts duplicate blocks after subpiece leaves waiting (overwrite path)" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash, 0)
    peer = Peer.id()

    with_model(torrent, fn _ ->
      state =
        State.make({hash, 0})
        |> Map.put(:mode, :endgame)
        |> Map.put(:waiting, [])

      good = :binary.copy(<<0x42>>, 16 * 1024)

      # Duplicate/endgame-late arrival: not in waiting and no in-flight request.
      # Must not crash; endgame path calls FileHandle.write (needs live torrent).
      assert %State{} =
               State.response(state, peer, 0, good)
    end)
  end

  test "entering endgame re-opens blocks that are exclusively in flight" do
    hash = :crypto.strong_rand_bytes(20)
    peer_a = Peer.id()
    peer_b = Peer.id()
    noop = fn _index, _begin, _length -> :ok end

    with_model(sample_torrent(hash, 0), fn _ ->
      # Normal mode with every block claimed by one peer. `waiting` is empty, so
      # a second peer holding the piece has nothing it may ask for — one block
      # belongs to one peer. That is correct mid-download and fatal on the last
      # piece: if the holder stalls, the block is only retried on its own
      # timeout, and the peers that could supply it just wait.
      claimed = State.make({hash, 0}).waiting
      requests = Enum.map(claimed, &%Request{peer_id: peer_a, subpiece: &1, timer: nil})

      normal =
        State.make({hash, 0})
        |> Map.merge(%{waiting: [], requests: requests, monitoring: %{peer_b => make_ref()}})

      assert State.request(normal, peer_b, noop) == normal

      endgame = State.enter_endgame(normal)

      assert endgame.mode == :endgame
      assert Enum.sort(endgame.waiting) == Enum.sort(claimed)
      # The in-flight requests survive: endgame adds sources for a block, it
      # does not take it away from the peer already fetching it.
      assert endgame.requests == requests

      served = State.request(endgame, peer_b, noop)
      assert Enum.any?(served.requests, &(&1.peer_id == peer_b))

      # Level-triggered from the controller's reconcile pump, so it runs every
      # couple of seconds for the whole endgame: it must not re-queue anything.
      assert State.enter_endgame(endgame) == endgame
    end)
  end

  defp sample_torrent(hash, last_index) do
    piece_len = 16 * 384

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => piece_len}},
      left: 100_000,
      last_index: last_index,
      last_piece_length: piece_len
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
end

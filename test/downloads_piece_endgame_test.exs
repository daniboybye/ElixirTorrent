defmodule DownloadsPieceEndgameTest do
  use ExUnit.Case, async: false

  alias Torrent.Downloads.Piece.State

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

defmodule PieceVerifyInvalidateTest do
  use ExUnit.Case, async: true

  alias Torrent.FileHandle.Piece

  @piece_len 32 * 1024

  setup do
    hash = :crypto.strong_rand_bytes(20)

    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => @piece_len}},
      left: @piece_len,
      last_index: 0,
      last_piece_length: @piece_len
    }

    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)

    on_exit(fn ->
      try do
        if Process.alive?(model_pid), do: GenServer.stop(model_pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, hash: hash}
  end

  test "download verify failure zeroes the piece on disk for retry", %{hash: hash} do
    dir = Path.join(System.tmp_dir!(), "piece_inval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "data.bin")
    File.write!(path, :binary.copy(<<0xAB>>, @piece_len))

    piece = %Piece{hash: hash, offset: 0, files: [{path, @piece_len}], length: @piece_len}

    refute Piece.check(hash, 0, piece, :download)
    assert File.read!(path) == :binary.copy(<<0>>, @piece_len)
  end

  test "resume verify failure does not zero the piece on disk", %{hash: hash} do
    dir = Path.join(System.tmp_dir!(), "piece_inval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "data.bin")
    original = :binary.copy(<<0xCD>>, @piece_len)
    File.write!(path, original)

    piece = %Piece{hash: hash, offset: 0, files: [{path, @piece_len}], length: @piece_len}

    refute Piece.check(hash, 0, piece, :resume)
    assert File.read!(path) == original
  end
end

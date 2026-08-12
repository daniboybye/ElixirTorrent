defmodule Cycle3V2GapStorageCoverageTest do
  @moduledoc """
  Coverage for reading and writing across BEP 52 padding gaps.

  In a v2 torrent every file starts on a piece boundary, so the byte stream a
  piece covers is "file bytes, then padding up to the next boundary". That
  padding has no file behind it: `Torrent.FileHandle.Piece` models it as a
  `{:gap, length}` entry it must skip on write and synthesise as zero bytes on
  read. Getting this wrong silently corrupts the tail of every file whose length
  is not a multiple of the piece length — which is almost all of them.
  """
  use ExUnit.Case, async: false

  alias Torrent.{FileHandle, Merkle}

  @piece_length 16_384
  @file_length 10_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "a piece that runs past the end of its file writes only the file bytes" do
    %{torrent: torrent, content: content} = start_v2_torrent!()

    padded = content <> :binary.copy(<<0>>, @piece_length - @file_length)

    :ok = FileHandle.write(torrent.hash, 0, 0, padded)
    :ok = FileHandle.flush(torrent.hash, 0)

    path = Path.join(torrent.download_dir, "part.bin")
    # The padding must not be appended to the file on disk.
    assert File.stat!(path).size == @file_length
    assert File.read!(path) == content
  end

  test "a piece read returns exactly the file bytes behind it" do
    %{torrent: torrent, content: content} = start_v2_torrent!()

    :ok = FileHandle.write(torrent.hash, 0, 0, content)
    :ok = FileHandle.flush(torrent.hash, 0)

    assert {:ok, ^content} = FileHandle.read(torrent.hash, 0, 0, @file_length)
    # A read that would run into the padding is refused rather than padded.
    assert :error = FileHandle.read(torrent.hash, 0, 0, @piece_length)
  end

  test "flushing a piece with no worker is a no-op" do
    hash = :crypto.strong_rand_bytes(20)
    assert :ok = FileHandle.flush(hash, 0)
  end

  ## helpers -----------------------------------------------------------------

  defp start_v2_torrent! do
    content = :crypto.strong_rand_bytes(@file_length)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)

    merkle = %{
      piece_length: @piece_length,
      files: [
        %{path: ["part.bin"], length: @file_length, pieces_root: root, piece_hashes: [root]}
      ]
    }

    {:ok, layout} = Merkle.piece_stream_layout(merkle)

    # The layout must actually contain padding, otherwise this test proves
    # nothing about the gap clauses.
    assert Enum.any?(layout.all_files, &match?({_, {:gap, _}}, &1))

    torrent = v2_torrent(merkle, layout, tmp_dir())

    Torrent.PiecesStatistic.init(torrent)
    start_supervised!({Torrent.Model, torrent})
    {:ok, fh} = Torrent.FileHandle.start_link(torrent.hash)
    on_exit(fn -> TestSupport.Sync.safe_stop(fh, 500) end)

    %{torrent: torrent, content: content}
  end

  defp v2_torrent(merkle, layout, dir) do
    %Torrent{
      hash: :crypto.strong_rand_bytes(20),
      metadata: %{
        "info" => %{
          "name" => "v2gap",
          "piece length" => @piece_length,
          "file tree" => %{},
          "meta version" => 2
        }
      },
      left: layout.content_length,
      last_index: layout.piece_count - 1,
      last_piece_length: List.last(layout.piece_lengths),
      piece_lengths: layout.piece_lengths,
      download_dir: dir,
      kind: :v2,
      merkle: merkle
    }
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "et_v2_gap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end

defmodule Torrent.V2StorageTest do
  use ExUnit.Case, async: false

  alias Torrent.FileHandle

  defp torrent(kind, merkle) do
    hash = :crypto.strong_rand_bytes(20)

    dir =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_v2_store_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "length" => 1,
          "name" => "one-byte.bin",
          "piece length" => 16_384,
          "pieces" => :binary.copy(<<7>>, 20)
        }
      },
      left: 1,
      last_index: 0,
      last_piece_length: 1,
      download_dir: dir,
      kind: kind,
      merkle: merkle
    }
  end

  test "Store publishes parsed v2 merkle data beside the v1 SHA-1 blob" do
    root = :binary.copy(<<9>>, 32)

    merkle = %{
      piece_length: 16_384,
      files: [
        %{path: ["one-byte.bin"], length: 1, pieces_root: root, piece_hashes: [root]}
      ]
    }

    torrent = torrent(:hybrid, merkle)
    start_supervised!({Torrent.Model, torrent})
    start_supervised!({Torrent.FileHandle.Store, torrent.hash})

    context = FileHandle.context(torrent.hash)
    assert context.pieces_hash == :binary.copy(<<7>>, 20)
    assert context.v2_merkle == merkle
  end

  test "Store leaves the additive v2 field nil for v1 torrents" do
    torrent = torrent(:v1, nil)
    start_supervised!({Torrent.Model, torrent})
    start_supervised!({Torrent.FileHandle.Store, torrent.hash})

    assert FileHandle.context(torrent.hash).v2_merkle == nil
  end
end

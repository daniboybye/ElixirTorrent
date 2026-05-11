defmodule Torrent.V2StorageTest do
  use ExUnit.Case, async: false

  alias Torrent.{FileHandle, Merkle}

  @piece_length 16_384

  defp torrent(kind, merkle, opts \\ []) do
    hash = Keyword.get(opts, :hash, :crypto.strong_rand_bytes(20))

    dir =
      Keyword.get(
        opts,
        :dir,
        Path.join(
          System.tmp_dir!(),
          "elixir_torrent_v2_store_#{System.unique_integer([:positive])}"
        )
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    piece_lengths = Keyword.get(opts, :piece_lengths)
    last_index = Keyword.get(opts, :last_index, 0)
    last_piece_length = Keyword.get(opts, :last_piece_length, 1)
    left = Keyword.get(opts, :left, 1)

    %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "length" => left,
          "name" => "one-byte.bin",
          "piece length" => @piece_length,
          "pieces" => Map.get(Keyword.get(opts, :info, %{}), "pieces", :binary.copy(<<7>>, 20))
        }
      },
      left: left,
      last_index: last_index,
      last_piece_length: last_piece_length,
      piece_lengths: piece_lengths,
      download_dir: dir,
      kind: kind,
      merkle: merkle
    }
  end

  defp start_store!(torrent) do
    Torrent.PiecesStatistic.init(torrent)
    start_supervised!({Torrent.Model, torrent})
    start_supervised!({Torrent.FileHandle.Store, torrent.hash})
  end

  test "Store publishes parsed v2 merkle data beside the v1 SHA-1 blob" do
    root = :binary.copy(<<9>>, 32)

    merkle = %{
      piece_length: @piece_length,
      files: [
        %{path: ["one-byte.bin"], length: 1, pieces_root: root, piece_hashes: [root]}
      ]
    }

    torrent = torrent(:hybrid, merkle)
    start_store!(torrent)

    context = FileHandle.context(torrent.hash)
    assert context.pieces_hash == :binary.copy(<<7>>, 20)
    assert context.v2_merkle == merkle
    assert context.kind == :hybrid
  end

  test "Store leaves the additive v2 field nil for v1 torrents" do
    torrent = torrent(:v1, nil)
    start_store!(torrent)

    assert FileHandle.context(torrent.hash).v2_merkle == nil
  end

  test "pure-v2 Store builds aligned layout with gap entries and piece specs" do
    content = :binary.copy(<<0xCD>>, 10_000)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)

    merkle = %{
      piece_length: @piece_length,
      files: [
        %{path: ["part.bin"], length: 10_000, pieces_root: root, piece_hashes: [root]}
      ]
    }

    {:ok, layout} = Merkle.piece_stream_layout(merkle)

    torrent =
      torrent(:v2, merkle,
        left: layout.content_length,
        last_index: layout.piece_count - 1,
        last_piece_length: List.last(layout.piece_lengths),
        piece_lengths: layout.piece_lengths,
        info: %{"pieces" => nil}
      )
      |> Map.put(:metadata, %{
        "info" => %{
          "name" => "v2dir",
          "piece length" => @piece_length,
          "file tree" => %{},
          "meta version" => 2
        }
      })

    start_store!(torrent)
    ctx = FileHandle.context(torrent.hash)

    assert ctx.kind == :v2
    assert is_nil(ctx.pieces_hash)
    assert length(ctx.piece_specs) == 1

    assert Enum.any?(ctx.all_files, fn
             {_, {:gap, _}} -> true
             _ -> false
           end)
  end

  test "pure-v2 piece verify passes on matching bytes" do
    content = :binary.copy(<<0xEE>>, 500)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)

    merkle = %{
      piece_length: @piece_length,
      files: [
        %{path: ["small.bin"], length: 500, pieces_root: root, piece_hashes: [root]}
      ]
    }

    {:ok, layout} = Merkle.piece_stream_layout(merkle)

    dir =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_v2_verify_ok_#{System.unique_integer([:positive])}"
      )

    torrent =
      torrent(:v2, merkle,
        dir: dir,
        left: layout.content_length,
        last_index: 0,
        last_piece_length: List.last(layout.piece_lengths),
        piece_lengths: layout.piece_lengths,
        info: %{"pieces" => nil}
      )
      |> Map.put(:metadata, %{
        "info" => %{
          "name" => "v2dir",
          "piece length" => @piece_length,
          "file tree" => %{},
          "meta version" => 2
        }
      })

    start_store!(torrent)

    path = Path.join(dir, "small.bin")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    assert FileHandle.verify(torrent.hash, 0, :resume)
  end

  test "pure-v2 piece verify fails on corrupt bytes" do
    content = :binary.copy(<<0xEE>>, 500)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)

    merkle = %{
      piece_length: @piece_length,
      files: [
        %{path: ["small.bin"], length: 500, pieces_root: root, piece_hashes: [root]}
      ]
    }

    {:ok, layout} = Merkle.piece_stream_layout(merkle)

    dir =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_v2_verify_bad_#{System.unique_integer([:positive])}"
      )

    torrent =
      torrent(:v2, merkle,
        dir: dir,
        left: layout.content_length,
        last_index: 0,
        last_piece_length: List.last(layout.piece_lengths),
        piece_lengths: layout.piece_lengths,
        info: %{"pieces" => nil}
      )
      |> Map.put(:metadata, %{
        "info" => %{
          "name" => "v2dir",
          "piece length" => @piece_length,
          "file tree" => %{},
          "meta version" => 2
        }
      })

    start_store!(torrent)

    path = Path.join(dir, "small.bin")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, 500))

    refute FileHandle.verify(torrent.hash, 0, :resume)
  end

  test "libtorrent pure-v2 fixture verifies its zero-filled golden pieces" do
    fixture = Path.join([__DIR__, "fixtures", "libtorrent_v2_only.torrent"])

    dir =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_v2_libtorrent_#{System.unique_integer([:positive])}"
      )

    torrent = fixture |> Torrent.parse_file!() |> Map.put(:download_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    start_store!(torrent)

    assert FileHandle.verify(torrent.hash, 0, :resume)
  end

  test "live FileHandle write and check verifies a short piece after an alignment gap" do
    content_a = :binary.copy(<<0xA1>>, 10_000)
    content_b = :binary.copy(<<0xB2>>, 500)
    {:ok, tree_a} = Merkle.build(content_a)
    {:ok, tree_b} = Merkle.build(content_b)

    merkle = %{
      piece_length: @piece_length,
      files: [
        %{
          path: ["a.bin"],
          length: byte_size(content_a),
          pieces_root: Merkle.root(tree_a),
          piece_hashes: [Merkle.root(tree_a)]
        },
        %{
          path: ["b.bin"],
          length: byte_size(content_b),
          pieces_root: Merkle.root(tree_b),
          piece_hashes: [Merkle.root(tree_b)]
        }
      ]
    }

    {:ok, layout} = Merkle.piece_stream_layout(merkle)

    torrent =
      torrent(:v2, merkle,
        left: layout.content_length,
        last_index: 1,
        last_piece_length: 500,
        piece_lengths: layout.piece_lengths,
        info: %{"pieces" => nil}
      )
      |> Map.put(:metadata, %{
        "info" => %{
          "name" => "v2dir",
          "piece length" => @piece_length,
          "file tree" => %{"a.bin" => %{}, "b.bin" => %{}},
          "meta version" => 2
        }
      })

    Torrent.PiecesStatistic.init(torrent)
    start_supervised!({Torrent.Model, torrent})
    start_supervised!({Torrent.FileHandle, torrent.hash})

    assert Torrent.Model.piece_length(torrent.hash, 1) == 500
    assert :ok = FileHandle.write(torrent.hash, 1, 0, content_b)
    assert FileHandle.check?(torrent.hash, 1)
  end

  test "Model.piece_length uses per-index v2 piece lengths" do
    merkle = %{
      piece_length: @piece_length,
      files: [
        %{
          path: ["a"],
          length: 10_000,
          pieces_root: :binary.copy(<<1>>, 32),
          piece_hashes: [:binary.copy(<<1>>, 32)]
        },
        %{
          path: ["b"],
          length: 500,
          pieces_root: :binary.copy(<<2>>, 32),
          piece_hashes: [:binary.copy(<<2>>, 32)]
        }
      ]
    }

    {:ok, layout} = Merkle.piece_stream_layout(merkle)

    torrent =
      torrent(:v2, merkle,
        left: layout.content_length,
        last_index: layout.piece_count - 1,
        last_piece_length: List.last(layout.piece_lengths),
        piece_lengths: layout.piece_lengths,
        info: %{"pieces" => nil}
      )

    start_supervised!({Torrent.Model, torrent})

    assert Torrent.Model.piece_length(torrent.hash, 0) == 10_000
    assert Torrent.Model.piece_length(torrent.hash, layout.piece_count - 1) == 500
  end
end

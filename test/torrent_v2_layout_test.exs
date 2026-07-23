defmodule Torrent.V2LayoutTest do
  use ExUnit.Case, async: true

  alias Torrent.Merkle

  @piece_length 16_384

  defp file(name, length, root) do
    %{
      path: [name],
      length: length,
      pieces_root: root,
      piece_hashes: [root]
    }
  end

  test "piece_stream_layout aligns files and records gap padding" do
    root_a = Merkle.root(elem(Merkle.build(:binary.copy(<<1>>, 10_000)), 1))
    root_b = Merkle.root(elem(Merkle.build(:binary.copy(<<2>>, 500)), 1))

    merkle = %{
      piece_length: @piece_length,
      files: [file("a.bin", 10_000, root_a), file("b.bin", 500, root_b)]
    }

    assert {:ok, layout} = Merkle.piece_stream_layout(merkle)
    assert layout.address_space_length == @piece_length + @piece_length
    assert layout.content_length == 10_500
    assert layout.piece_count == 2
    assert layout.piece_lengths == [10_000, 500]

    assert [%{file: %{path: ["a.bin"]}, file_piece_index: 0}, %{file: %{path: ["b.bin"]}}] =
             layout.piece_specs

    ends = Enum.map(layout.all_files, &elem(&1, 0))
    assert ends == Enum.sort(ends, :asc)

    assert Enum.count(layout.all_files, fn
             {_, {:gap, _}} -> true
             _ -> false
           end) >= 1
  end

  test "piece_stream_layout skips empty files" do
    merkle = %{
      piece_length: @piece_length,
      files: [
        %{path: ["empty"], length: 0, pieces_root: nil, piece_hashes: []},
        file("only.bin", 100, Merkle.root(elem(Merkle.build(:binary.copy(<<3>>, 100)), 1)))
      ]
    }

    assert {:ok, layout} = Merkle.piece_stream_layout(merkle)
    assert layout.piece_count == 1
    assert layout.piece_lengths == [100]

    assert Enum.any?(layout.all_files, fn
             {0, {:file, %{path: ["empty"], length: 0}, _}} -> true
             _ -> false
           end)
  end

  test "verify_file_piece accepts valid bytes and rejects corruption" do
    content = :binary.copy(<<9>>, 10_000)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)

    file = %{
      path: ["ten-k.bin"],
      length: byte_size(content),
      pieces_root: root,
      piece_hashes: [root]
    }

    piece_bytes = content

    assert Merkle.verify_file_piece(file, @piece_length, 0, piece_bytes)

    <<_first::8, rest::binary>> = piece_bytes
    corrupt = <<0, rest::binary>>
    refute Merkle.verify_file_piece(file, @piece_length, 0, corrupt)
  end

  test "expected_file_piece_hash uses root for single-piece files" do
    root = Merkle.root(elem(Merkle.build("tiny"), 1))
    file = file("tiny.bin", 4, root)
    assert Merkle.expected_file_piece_hash(file, @piece_length, 0) == root
    assert Merkle.expected_file_piece_hash(file, @piece_length, 1) == nil
  end

  test "verify_file_piece uses file-global leaf indices after the first piece" do
    content = :binary.copy(<<7>>, @piece_length) <> :binary.copy(<<8>>, 500)
    {:ok, tree} = Merkle.build(content)
    {:ok, piece_layer} = Merkle.piece_layer(tree, @piece_length)

    piece_hashes =
      for <<hash::binary-size(32) <- piece_layer>>, do: hash

    file = %{
      path: ["multi.bin"],
      length: byte_size(content),
      pieces_root: Merkle.root(tree),
      piece_hashes: piece_hashes
    }

    assert Merkle.verify_file_piece(file, @piece_length, 1, :binary.copy(<<8>>, 500))
  end
end

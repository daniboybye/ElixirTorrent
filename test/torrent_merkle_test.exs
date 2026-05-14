defmodule Torrent.MerkleTest do
  use ExUnit.Case, async: true

  alias Torrent.Merkle

  @block_size 16_384
  @zero_hash <<0::256>>

  defp hex(value), do: Base.decode16!(value, case: :lower)
  defp hash(value), do: :crypto.hash(:sha256, value)

  describe "build/1 and root/1" do
    test "single short block uses the digest directly as its root" do
      content = "short file"
      assert {:ok, tree} = Merkle.build(content)
      assert Merkle.root(tree) == hash(content)
      assert {:ok, <<>>} = Merkle.piece_layer(tree, @block_size)
      assert {:ok, []} = Merkle.proof(tree, 0)
    end

    test "a short final block is hashed without zero-filling its content" do
      first = :binary.copy("a", @block_size)
      final = "tail"
      assert {:ok, tree} = Merkle.build(first <> final)

      expected = hash(hash(first) <> hash(final))
      refute expected == hash(hash(first) <> hash(final <> :binary.copy(<<0>>, @block_size - 4)))
      assert Merkle.root(tree) == expected
    end

    test "three leaves use a zero hash as the fourth leaf" do
      content =
        :binary.copy("a", @block_size) <>
          :binary.copy("b", @block_size) <>
          :binary.copy("c", @block_size)

      # Independently generated with Python hashlib:
      # H=lambda b: hashlib.sha256(b).digest(); H(H(a)+H(b)) and
      # H(H(c)+bytes(32)), followed by H(left_parent+right_parent).
      expected_root = hex("839c7d023a90b3dcb32e0213f038ac6b446dc1e1e07296edf9281ae3e1acac81")

      assert {:ok, tree} = Merkle.build(content)
      assert Merkle.root(tree) == expected_root

      refute Merkle.root(tree) ==
               hash(
                 hash(
                   hash(:binary.copy("a", @block_size)) <> hash(:binary.copy("b", @block_size))
                 ) <> hash(hash(:binary.copy("c", @block_size)) <> hash(<<>>))
               )
    end

    test "rejects an empty file because BEP 52 assigns it no pieces root" do
      assert Merkle.build(<<>>) == {:error, :empty_file}
      assert Merkle.build_from_leaf_hashes([]) == {:error, :empty_file}
      assert Merkle.build_from_leaf_hashes([<<1>>]) == {:error, :invalid_hash}
    end
  end

  describe "proof/3 and verify/4" do
    setup do
      leaves =
        for byte <- [?a, ?b, ?c] do
          hash(:binary.copy(<<byte>>, @block_size))
        end

      {:ok, tree} = Merkle.build_from_leaf_hashes(leaves)
      %{tree: tree, leaves: leaves}
    end

    test "leaf proof is ordered from the leaf towards the root", %{tree: tree, leaves: leaves} do
      parent_ab = hex("91ba1b58ae584fde9a26d7f74fb955d515d1c576c1c7e865a0bac16d81fa10b3")

      assert {:ok, [@zero_hash, ^parent_ab] = proof} = Merkle.proof(tree, 2)
      assert Merkle.verify(Merkle.root(tree), 2, Enum.at(leaves, 2), proof)
      refute Merkle.verify(Merkle.root(tree), 2, Enum.at(leaves, 1), proof)
      refute Merkle.verify(Merkle.root(tree), 2, Enum.at(leaves, 2), Enum.reverse(proof))
    end

    test "piece-layer proof uses an index relative to that layer", %{tree: tree} do
      parent_ab = hex("91ba1b58ae584fde9a26d7f74fb955d515d1c576c1c7e865a0bac16d81fa10b3")
      parent_c_pad = hex("a0adee07b4e9ce4348f8fc08effa760346c76991789d45cc388f0b24b99419ca")

      assert {:ok, [^parent_ab]} = Merkle.proof(tree, 1, 1)
      assert Merkle.verify(Merkle.root(tree), 1, parent_c_pad, [parent_ab])
    end

    test "rejects padding and out-of-tree indices", %{tree: tree} do
      assert Merkle.proof(tree, 3) == {:error, :invalid_index}
      assert Merkle.proof(tree, 0, 3) == {:error, :invalid_layer}
    end
  end

  describe "piece_layer/2" do
    test "extracts only hashes covering real file data" do
      blocks = for byte <- [?a, ?b, ?c, ?d, ?e], do: :binary.copy(<<byte>>, @block_size)
      assert {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))

      first_piece = hash(hash(Enum.at(blocks, 0)) <> hash(Enum.at(blocks, 1)))
      second_piece = hash(hash(Enum.at(blocks, 2)) <> hash(Enum.at(blocks, 3)))
      third_piece = hash(hash(Enum.at(blocks, 4)) <> @zero_hash)

      assert {:ok, layer} = Merkle.piece_layer(tree, 2 * @block_size)
      assert layer == first_piece <> second_piece <> third_piece

      assert :ok =
               Merkle.validate_piece_layer(
                 Merkle.root(tree),
                 layer,
                 5 * @block_size,
                 2 * @block_size
               )
    end

    test "requires a power-of-two piece length of at least 16 KiB" do
      assert {:ok, tree} = Merkle.build("content")
      assert Merkle.piece_layer(tree, 32_000) == {:error, :invalid_piece_length}
      assert Merkle.piece_layer(tree, 8_192) == {:error, :invalid_piece_length}
    end
  end

  describe "parse_metadata/1" do
    test "validates libtorrent's real multi-piece v2 fixture" do
      # Upstream golden file:
      # github.com/arvidn/libtorrent/RC_2_0/test/test_torrents/v2_multipiece_file.torrent
      path = Path.join([__DIR__, "fixtures", "libtorrent_v2_multipiece_file.torrent"])

      metadata =
        path
        |> File.read!()
        |> Bento.decode!()

      expected_root = hex("515ea9181744b817744ded9d2e8e9dc6a8450c0b0c52e24b5077f302ffbd9008")
      expected_piece = hex("60aae9c7b428f87e0713e88229e18f0adf12cd7b22a0dd8a92bb2485eb7af242")

      assert {:ok, %{piece_length: 65_536, files: [file]}} = Merkle.parse_metadata(metadata)
      assert file.path == ["test1MB"]
      assert file.length == 1_048_576
      assert file.pieces_root == expected_root
      assert file.piece_hashes == List.duplicate(expected_piece, 16)
    end

    test "rejects a piece layer whose hashes do not reconstruct the claimed root" do
      path = Path.join([__DIR__, "fixtures", "libtorrent_v2_multipiece_file.torrent"])

      metadata =
        path
        |> File.read!()
        |> Bento.decode!()

      [{root, layer}] = Map.to_list(metadata["piece layers"])
      <<first, rest::binary>> = layer

      bad_metadata =
        put_in(metadata, ["piece layers", root], <<Bitwise.bxor(first, 1), rest::binary>>)

      assert Merkle.parse_metadata(bad_metadata) == {:error, :piece_layer_root_mismatch}
    end

    test "requires the top-level piece layers dictionary and rejects orphan roots" do
      path = Path.join([__DIR__, "fixtures", "libtorrent_v2_multipiece_file.torrent"])

      metadata =
        path
        |> File.read!()
        |> Bento.decode!()

      assert metadata
             |> Map.delete("piece layers")
             |> Merkle.parse_metadata() == {:error, :missing_piece_layers}

      orphan_root = :binary.copy(<<255>>, 32)
      metadata = put_in(metadata, ["piece layers", orphan_root], <<0::256>>)
      assert Merkle.parse_metadata(metadata) == {:error, :invalid_piece_layer_keys}
    end

    test "normalizes an empty file without a pieces root" do
      metadata = %{
        "info" => %{
          "file tree" => %{"empty" => %{"" => %{"length" => 0}}},
          "meta version" => 2,
          "piece length" => @block_size
        },
        "piece layers" => %{}
      }

      assert {:ok,
              %{
                files: [
                  %{path: ["empty"], length: 0, pieces_root: nil, piece_hashes: []}
                ]
              }} = Merkle.parse_metadata(metadata)
    end
  end
end

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

    test "rejects non-v2 metadata and malformed file tree nodes" do
      assert Merkle.parse_metadata(%{}) == {:error, :missing_v2_metadata}

      assert Merkle.parse_metadata(%{"info" => %{"meta version" => 1}}) ==
               {:error, :missing_v2_metadata}

      root = hash("valid-root")

      assert Merkle.parse_metadata(
               v2_metadata(%{
                 "file tree" => %{
                   "bad-root" => %{"" => %{"length" => @block_size, "pieces root" => <<0::120>>}}
                 },
                 "piece layers" => %{}
               })
             ) == {:error, :invalid_pieces_root}

      assert Merkle.parse_metadata(
               v2_metadata(%{
                 "file tree" => %{
                   "" => %{"length" => @block_size, "pieces root" => root}
                 },
                 "piece layers" => %{}
               })
             ) == {:error, :invalid_file_tree}

      assert Merkle.parse_metadata(
               v2_metadata(%{
                 "file tree" => %{
                   "ok" => %{
                     "leaf" => %{"" => %{"length" => @block_size, "pieces root" => root}}
                   },
                   "broken" => "not-a-map"
                 },
                 "piece layers" => %{}
               })
             ) == {:error, :invalid_file_tree}
    end
  end

  describe "validate_hash_request/5 and range_response/5 bounds" do
    setup do
      blocks = for byte <- [?a, ?b, ?c, ?d], do: :binary.copy(<<byte>>, @block_size)
      {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))
      %{tree: tree}
    end

    test "rejects invalid BEP 52 request shape atoms", %{tree: tree} do
      assert Merkle.validate_hash_request(tree, 0, 1, 2, 1) == {:error, :invalid_index}
      assert Merkle.validate_hash_request(tree, 0, 0, 3, 1) == {:error, :invalid_length}
      assert Merkle.validate_hash_request(tree, 0, 0, 2, 9) == {:error, :invalid_proof_layers}
      assert Merkle.validate_hash_request(tree, 3, 0, 2, 1) == {:error, :invalid_base_layer}
      assert Merkle.validate_hash_request(tree, 0, 4, 2, 1) == {:error, :invalid_index}

      assert Merkle.range_response(tree, 0, 1, 2, 1) == {:error, :invalid_index}
      assert Merkle.range_response(tree, 0, 0, 3, 1) == {:error, :invalid_length}
    end
  end

  describe "range_response_from_layer/6 metadata bounds" do
    test "rejects out-of-range indices, proof depth, and root mismatch" do
      blocks = for byte <- [?a, ?b, ?c, ?d], do: :binary.copy(<<byte>>, @block_size)
      {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))
      root = Merkle.root(tree)
      piece_length = 2 * @block_size
      {:ok, layer} = Merkle.piece_layer_level(piece_length)
      nodes = Enum.at(tree.levels, layer)

      assert Merkle.range_response_from_layer(nodes, layer, root, 0, 4, 2) ==
               {:error, :invalid_index}

      assert Merkle.range_response_from_layer(nodes, layer, root, 0, 2, 9) ==
               {:error, :invalid_proof_layers}

      assert Merkle.range_response_from_layer(nodes, layer, <<0::256>>, 0, 2, 0) ==
               {:error, :root_mismatch}

      assert Merkle.range_response(tree, layer + 1, 0, 2, 1) == {:error, :invalid_base_layer}
    end
  end

  describe "proof/3, verify/4, verify_hashes/7 guards" do
    setup do
      {:ok, tree} = Merkle.build("leaf-bytes")
      %{tree: tree, root: Merkle.root(tree)}
    end

    test "proof falls back on negative layer or index", %{tree: tree} do
      assert Merkle.proof(tree, -1) == {:error, :invalid_index}
      assert Merkle.proof(tree, 0, -1) == {:error, :invalid_index}
    end

    test "verify and verify_hashes reject malformed wire inputs", %{tree: _tree} do
      blocks = for byte <- [?a, ?b, ?c, ?d], do: :binary.copy(<<byte>>, @block_size)
      {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))
      root = Merkle.root(tree)
      leaf = Merkle.leaf_hashes("leaf-bytes") |> hd()

      refute Merkle.verify(<<0::248>>, 0, leaf, [])
      refute Merkle.verify(root, 0, leaf, "not-a-list")

      {:ok, hashes} = Merkle.range_response(tree, 0, 0, 2, 1)

      refute Merkle.verify_hashes(<<0::248>>, 0, 0, 2, 1, hashes, 4)
      refute Merkle.verify_hashes(root, 0, 0, 2, 1, hashes, 0)
      refute Merkle.verify_hashes(root, 0, 0, 2, 1, tl(hashes), 4)
    end

    test "verify_hashes rejects conflicting sibling proofs during flat insertion" do
      blocks =
        for byte <- [?a, ?b, ?c, ?d, ?e, ?f, ?g, ?h], do: :binary.copy(<<byte>>, @block_size)

      content = IO.iodata_to_binary(blocks)
      {:ok, tree} = Merkle.build(content)
      root = Merkle.root(tree)

      assert {:ok, hashes} = Merkle.range_response(tree, 0, 0, 2, 2)
      base_len = 2
      {base, proofs} = Enum.split(hashes, base_len)
      [p0, p1 | rest] = proofs
      flipped = <<Bitwise.bxor(:binary.at(p0, 0), 1)::8, binary_part(p0, 1, 31)::binary>>
      conflict = base ++ [p0, flipped, p1 | rest]

      refute Merkle.verify_hashes(root, 0, 0, 2, 2, conflict, 8)
    end
  end

  describe "piece_node/3 and leaf_read_indices/5" do
    test "piece_node enforces piece length and piece index bounds" do
      blocks = for byte <- [?a, ?b, ?c, ?d], do: :binary.copy(<<byte>>, @block_size)
      {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))

      assert Merkle.piece_node(tree, 32_000, 0) == {:error, :invalid_piece_length}
      assert Merkle.piece_node(tree, 2 * @block_size, 99) == {:error, :invalid_index}

      {:ok, node} = Merkle.piece_node(tree, 2 * @block_size, 0)
      assert byte_size(node) == 32
    end

    test "leaf_read_indices returns empty set for invalid piece length" do
      assert Merkle.leaf_read_indices(64, 9999, 0, 2, 2) == []
    end
  end

  describe "piece stream layout and per-piece hashing" do
    test "expected_file_piece_hash selects indexed piece digests and rejects unknown indices" do
      file = %{length: 0, piece_hashes: []}
      assert Merkle.expected_file_piece_hash(file, @block_size, 0) == nil

      roots = for n <- 1..3, do: hash("piece-#{n}")

      multi = %{
        length: 3 * @block_size,
        piece_hashes: roots
      }

      assert Merkle.expected_file_piece_hash(multi, @block_size, 0) == hd(roots)
      assert Merkle.expected_file_piece_hash(multi, @block_size, 1) == Enum.at(roots, 1)
      assert Merkle.expected_file_piece_hash(multi, @block_size, 9) == nil
    end

    test "hash_file_piece_bytes uses zero-hash leaves for unfilled blocks in a piece" do
      piece_length = 2 * @block_size
      file_data = :binary.copy(<<?a>>, @block_size)
      leaf0 = hash(file_data)
      expected_piece = hash(leaf0 <> @zero_hash)
      file = %{length: @block_size, piece_hashes: [expected_piece]}

      piece_bytes = file_data <> :binary.copy(<<0>>, @block_size)
      computed = Merkle.hash_file_piece_bytes(file, piece_length, 0, piece_bytes)

      assert computed == expected_piece
      assert Merkle.verify_file_piece(file, piece_length, 0, piece_bytes)
    end

    test "piece_stream_layout inserts alignment gaps between files" do
      root_a = hash("file-a")
      root_b = hash("file-b")

      {:ok, layout} =
        Merkle.piece_stream_layout(%{
          piece_length: @block_size,
          files: [
            %{path: ["a"], length: 100, pieces_root: root_a, piece_hashes: [root_a]},
            %{path: ["b"], length: @block_size, pieces_root: root_b, piece_hashes: [root_b]}
          ]
        })

      assert layout.piece_count == 2
      assert layout.content_length == @block_size + 100
      assert layout.address_space_length > layout.content_length
      assert Enum.any?(layout.all_files, fn {_offset, entry} -> match?({:gap, _}, entry) end)
      assert length(layout.piece_lengths) == 2
    end

    test "piece_stream_layout retains empty files without piece slots" do
      root = hash("data")

      {:ok, layout} =
        Merkle.piece_stream_layout(%{
          piece_length: @block_size,
          files: [
            %{path: ["empty"], length: 0, pieces_root: nil, piece_hashes: []},
            %{path: ["data"], length: @block_size, pieces_root: root, piece_hashes: [root]}
          ]
        })

      assert layout.piece_count == 1
      assert Enum.count(layout.all_files, fn {_o, {:file, f, _}} -> f.length == 0 end) == 1
    end

    test "parse_metadata normalizes single-piece files from their pieces root only" do
      root = hash("small-file")

      assert {:ok, %{files: [file]}} =
               Merkle.parse_metadata(
                 v2_metadata(%{
                   "file tree" => %{
                     "tiny" => %{"" => %{"length" => 100, "pieces root" => root}}
                   },
                   "piece layers" => %{}
                 })
               )

      assert file.piece_hashes == [root]
      assert file.length == 100
    end
  end

  describe "leaf_range_response_from_disk/7 proof paths" do
    test "serves proof siblings from disk with metadata-backed upper layers" do
      blocks =
        for byte <- [?a, ?b, ?c, ?d, ?e, ?f, ?g, ?h], do: :binary.copy(<<byte>>, @block_size)

      content = IO.iodata_to_binary(blocks)
      {:ok, tree} = Merkle.build(content)
      root = Merkle.root(tree)
      piece_length = 4 * @block_size
      {:ok, layer_bin} = Merkle.piece_layer(tree, piece_length)

      piece_hashes =
        for <<digest::binary-size(32) <- layer_bin>> do
          digest
        end

      dir = Path.join(System.tmp_dir!(), "merkle_proof_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "wide.bin")
      File.write!(path, content)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, from_tree} = Merkle.range_response(tree, 0, 0, 2, 2)

      assert {:ok, from_disk} =
               Merkle.leaf_range_response_from_disk(
                 path,
                 byte_size(content),
                 piece_hashes,
                 piece_length,
                 0,
                 2,
                 2
               )

      assert from_disk == from_tree
      assert Merkle.verify_hashes(root, 0, 0, 2, 2, from_disk, 8)
    end

    test "hashes beyond file end and padded leaf slots as zero leaves" do
      content = :binary.copy(<<?x>>, @block_size) <> :binary.copy(<<?y>>, @block_size) <> "tail"
      {:ok, tree} = Merkle.build(content)
      root = Merkle.root(tree)
      piece_hashes = hd(tree.levels)

      dir = Path.join(System.tmp_dir!(), "merkle_tail_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "tail.bin")
      File.write!(path, content)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, from_tree} = Merkle.range_response(tree, 0, 0, 2, 1)

      assert {:ok, from_disk} =
               Merkle.leaf_range_response_from_disk(
                 path,
                 byte_size(content),
                 piece_hashes,
                 @block_size,
                 0,
                 2,
                 1
               )

      assert from_disk == from_tree
      assert Merkle.verify_hashes(root, 0, 0, 2, 1, from_disk, 3)
    end

    test "disk proof path rebuilds internal cache subtrees below the piece layer" do
      blocks =
        for byte <- [?a, ?b, ?c, ?d, ?e, ?f, ?g, ?h], do: :binary.copy(<<byte>>, @block_size)

      content = IO.iodata_to_binary(blocks)
      {:ok, tree} = Merkle.build(content)
      root = Merkle.root(tree)
      piece_length = 4 * @block_size
      {:ok, layer_bin} = Merkle.piece_layer(tree, piece_length)
      piece_hashes = for <<digest::binary-size(32) <- layer_bin>>, do: digest

      dir = Path.join(System.tmp_dir!(), "merkle_internal_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "wide.bin")
      File.write!(path, content)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, from_tree} = Merkle.range_response(tree, 0, 2, 2, 2)

      assert {:ok, from_disk} =
               Merkle.leaf_range_response_from_disk(
                 path,
                 byte_size(content),
                 piece_hashes,
                 piece_length,
                 2,
                 2,
                 2
               )

      assert from_disk == from_tree
      assert Merkle.verify_hashes(root, 0, 2, 2, 2, from_disk, 8)
    end

    test "rejects invalid hash request shape before opening disk" do
      dir = Path.join(System.tmp_dir!(), "merkle_badreq_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "tiny.bin")
      File.write!(path, "x")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Merkle.leaf_range_response_from_disk(path, 1, [hash("x")], @block_size, 1, 2, 0) ==
               {:error, :invalid_index}
    end
  end

  describe "libtorrent flat proof helpers" do
    test "collect_proof_flat_siblings walks parents including root-adjacent slots" do
      siblings = Merkle.collect_proof_flat_siblings(8, 0, 2, 0, 4)
      assert is_list(siblings)
      assert siblings != []
      assert Enum.all?(siblings, &is_integer/1)
    end

    test "range_response uses padding siblings for out-of-band flat indices" do
      blocks = for byte <- [?a, ?b, ?c], do: :binary.copy(<<byte>>, @block_size)
      {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))

      assert {:ok, hashes} = Merkle.range_response(tree, 0, 0, 2, 1)
      assert length(hashes) == 2 + Merkle.proof_append_count(2, 1)
      assert Merkle.verify_hashes(Merkle.root(tree), 0, 0, 2, 1, hashes, 3)
    end
  end

  defp v2_metadata(overrides) do
    {piece_layers, info_overrides} = Map.pop(overrides, "piece layers", %{})

    info =
      Map.merge(
        %{"meta version" => 2, "piece length" => @block_size, "file tree" => %{}},
        info_overrides
      )

    %{"info" => info, "piece layers" => piece_layers}
  end
end

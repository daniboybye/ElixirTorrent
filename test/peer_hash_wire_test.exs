defmodule Peer.HashWireTest do
  use ExUnit.Case, async: true

  alias Peer.HashWire
  alias Torrent.Merkle

  @root :crypto.hash(:sha256, "root")

  test "encode/decode request header round-trip" do
    req = %HashWire{
      pieces_root: @root,
      base_layer: 2,
      index: 4,
      length: 4,
      proof_layers: 3
    }

    assert {:ok, decoded} = HashWire.decode_request(HashWire.encode_request(req))
    assert decoded == req
  end

  test "hashes body splits base and proof counts per BEP 52" do
    req = %HashWire{
      pieces_root: @root,
      base_layer: 0,
      index: 0,
      length: 4,
      proof_layers: 3
    }

    base = for _ <- 1..4, do: :crypto.strong_rand_bytes(32)
    proof = for _ <- 1..2, do: :crypto.strong_rand_bytes(32)
    blob = IO.iodata_to_binary(base ++ proof)

    assert HashWire.expected_hash_count(req) == 6
    assert byte_size(blob) == 6 * 32
    assert {:ok, decoded, ^blob} = HashWire.decode_hashes(HashWire.encode_hashes(req, blob))
    assert decoded == req
    assert HashWire.split_hashes(req, blob) == {:ok, {base, proof}}
  end

  test "validate_request enforces base layer, alignment, and length rules" do
    req = %HashWire{
      pieces_root: @root,
      base_layer: 0,
      index: 0,
      length: 4,
      proof_layers: 1
    }

    assert :ok = HashWire.validate_request(req, 2)
    assert {:error, :invalid_index} = HashWire.validate_request(%{req | index: 1}, 2)
    assert {:error, :invalid_length} = HashWire.validate_request(%{req | length: 3}, 2)
    assert {:error, :invalid_base_layer} = HashWire.validate_request(%{req | base_layer: 1}, 2)
  end

  test "reject payload equals request header" do
    req = %HashWire{
      pieces_root: @root,
      base_layer: 0,
      index: 0,
      length: 2,
      proof_layers: 0
    }

    assert HashWire.encode_reject(req) == HashWire.encode_request(req)
  end
end

defmodule Torrent.MerkleRangeTest do
  use ExUnit.Case, async: true

  alias Torrent.Merkle

  @block Merkle.block_size()

  setup do
    blocks =
      for byte <- [?a, ?b, ?c, ?d, ?e, ?f, ?g, ?h, ?i, ?j, ?k, ?l, ?m, ?n, ?o, ?p],
          do: :binary.copy(<<byte>>, @block)

    content = IO.iodata_to_binary(blocks)
    {:ok, tree} = Merkle.build(content)
    %{tree: tree, root: Merkle.root(tree), block_count: length(blocks)}
  end

  test "range_response matches libtorrent proof append count", %{
    tree: tree,
    root: root,
    block_count: bc
  } do
    assert {:ok, hashes} = Merkle.range_response(tree, 0, 0, 4, 3)
    assert length(hashes) == 6
    assert Merkle.verify_hashes(root, 0, 0, 4, 3, hashes, bc)
  end

  test "range_response_from_layer serves metadata-backed piece layer", %{
    tree: tree,
    root: root,
    block_count: bc
  } do
    piece_length = 2 * @block
    {:ok, layer} = Merkle.piece_layer_level(piece_length)
    nodes = tree.levels |> Enum.at(layer)

    assert {:ok, hashes} = Merkle.range_response_from_layer(nodes, layer, root, 0, 2, 2)
    assert length(hashes) == 4
    assert Merkle.verify_hashes(root, layer, 0, 2, 2, hashes, bc)
  end

  test "verify_hashes rejects tampered proof siblings", %{tree: tree, root: root, block_count: bc} do
    {:ok, hashes} = Merkle.range_response(tree, 0, 0, 4, 3)
    [first | rest] = hashes
    bad = [<<Bitwise.bxor(:binary.at(first, 0), 1)::8, binary_part(first, 1, 31)::binary>> | rest]
    refute Merkle.verify_hashes(root, 0, 0, 4, 3, bad, bc)
  end

  test "leaf_read_indices for small request stays bounded on large virtual file" do
    block_count = 1024
    piece_length = 4 * @block
    indices = Merkle.leaf_read_indices(block_count, piece_length, 0, 2, 2)
    assert length(indices) < block_count
    assert 0 in indices and 1 in indices
  end

  test "proof_layers zero generates no proof siblings and verifies to root" do
    blocks = for byte <- [?a, ?b, ?c, ?d], do: :binary.copy(<<byte>>, @block)
    {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))
    root = Merkle.root(tree)

    assert Merkle.proof_append_count(4, 0) == 0
    assert Merkle.expected_response_count(4, 0) == 4
    assert Merkle.collect_proof_flat_siblings(4, 0, 4, 0) == []

    assert {:ok, hashes} = Merkle.range_response(tree, 0, 0, 4, 0)
    assert length(hashes) == 4
    assert Merkle.verify_hashes(root, 0, 0, 4, 0, hashes, 4)
  end

  test "short final disk leaf hashes truncated bytes matching memory tree" do
    partial = 1000
    content = :binary.copy(<<?z>>, @block) <> :binary.copy(<<?y>>, partial)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)
    piece_length = @block
    piece_hashes = tree.levels |> hd()

    dir = Path.join(System.tmp_dir!(), "merkle_short_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "short.bin")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, from_tree} = Merkle.range_response(tree, 0, 0, 2, 0)

    assert {:ok, from_disk} =
             Merkle.leaf_range_response_from_disk(
               path,
               byte_size(content),
               piece_hashes,
               piece_length,
               0,
               2,
               0
             )

    assert from_disk == from_tree
    assert Merkle.verify_hashes(root, 0, 0, 2, 0, from_disk, 2)
  end

  test "million-block request read index set stays far below file size" do
    block_count = 1_048_576
    piece_length = 4 * @block
    indices = Merkle.leaf_read_indices(block_count, piece_length, 0, 512, 19)
    assert length(indices) < 10_000
    assert length(indices) < block_count
  end
end

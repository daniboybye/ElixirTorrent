defmodule Torrent.Merkle do
  @moduledoc """
  BitTorrent v2 per-file Merkle trees from BEP 52.

  Leaves are SHA-256 hashes of consecutive 16 KiB file blocks. Trees are
  balanced to the next power of two with all-zero 32-byte leaf hashes. Proofs
  are returned from the requested node towards the root, which is also the
  ordering used by BEP 52 `hashes` messages.
  """

  @block_size 16_384
  @hash_size 32
  @zero_hash <<0::256>>

  @enforce_keys [:levels, :block_count]
  defstruct [:levels, :block_count]

  @type hash :: <<_::256>>
  @type t :: %__MODULE__{
          levels: [[hash()]],
          block_count: pos_integer()
        }

  @type file_context :: %{
          path: [binary()],
          length: non_neg_integer(),
          pieces_root: hash() | nil,
          piece_hashes: [hash()]
        }

  @type metadata_context :: %{
          piece_length: pos_integer(),
          files: [file_context()]
        }

  @doc "The fixed BEP 52 leaf block size."
  @spec block_size() :: pos_integer()
  def block_size, do: @block_size

  @doc "Returns SHA-256 hashes of consecutive 16 KiB blocks."
  @spec leaf_hashes(binary()) :: [hash()]
  def leaf_hashes(content) when is_binary(content), do: hash_blocks(content, [])

  @doc """
  Builds a complete per-file tree from file content.

  BEP 52 does not assign a pieces root to an empty file, so empty content
  returns `{:error, :empty_file}`.
  """
  @spec build(binary()) :: {:ok, t()} | {:error, :empty_file}
  def build(content) when is_binary(content), do: build_from_leaf_hashes(leaf_hashes(content))

  @doc """
  Builds a complete tree from already-computed leaf hashes.

  Missing leaves up to the next power of two are the 32-byte zero hash itself,
  not the digest of an empty or zero-filled data block.
  """
  @spec build_from_leaf_hashes([hash()]) ::
          {:ok, t()} | {:error, :empty_file | :invalid_hash}
  def build_from_leaf_hashes([]), do: {:error, :empty_file}

  def build_from_leaf_hashes(hashes) when is_list(hashes) do
    if Enum.all?(hashes, &valid_hash?/1) do
      padded =
        hashes ++ List.duplicate(@zero_hash, next_power_of_two(length(hashes)) - length(hashes))

      {:ok, %__MODULE__{levels: build_levels([padded]), block_count: length(hashes)}}
    else
      {:error, :invalid_hash}
    end
  end

  @doc "Returns the 32-byte pieces root of a built tree."
  @spec root(t()) :: hash()
  def root(%__MODULE__{levels: levels}), do: levels |> List.last() |> hd()

  @doc """
  Returns the concatenated BEP 52 piece-layer hashes for a file.

  The metainfo `piece layers` dictionary omits files no larger than one piece,
  so those files return an empty binary.
  """
  @spec piece_layer(t(), pos_integer()) ::
          {:ok, binary()} | {:error, :invalid_piece_length}
  def piece_layer(%__MODULE__{} = tree, piece_length) do
    with {:ok, layer} <- piece_layer_level(piece_length) do
      blocks_per_piece = div(piece_length, @block_size)
      piece_count = ceil_div(tree.block_count, blocks_per_piece)

      if piece_count <= 1 do
        {:ok, <<>>}
      else
        hashes = tree.levels |> Enum.at(layer) |> Enum.take(piece_count)
        {:ok, IO.iodata_to_binary(hashes)}
      end
    end
  end

  @doc """
  Returns sibling hashes proving a node at `layer` and `index`.

  Layer zero is the 16 KiB leaf layer. Siblings are ordered bottom-up, ready
  for `verify/4` and for the proof portion of a BEP 52 `hashes` response.
  """
  @spec proof(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [hash()]} | {:error, :invalid_index | :invalid_layer}
  def proof(tree, index, layer \\ 0)

  def proof(%__MODULE__{levels: levels, block_count: block_count}, index, layer)
      when is_integer(index) and index >= 0 and is_integer(layer) and layer >= 0 do
    actual_nodes = ceil_div(block_count, Integer.pow(2, layer))

    cond do
      layer >= length(levels) ->
        {:error, :invalid_layer}

      index >= actual_nodes ->
        {:error, :invalid_index}

      true ->
        proof =
          levels
          |> Enum.drop(layer)
          |> Enum.drop(-1)
          |> Enum.reduce({index, []}, fn nodes, {node_index, siblings} ->
            sibling_index = Bitwise.bxor(node_index, 1)
            {div(node_index, 2), [Enum.at(nodes, sibling_index) | siblings]}
          end)
          |> elem(1)
          |> Enum.reverse()

        {:ok, proof}
    end
  end

  def proof(%__MODULE__{}, _index, _layer), do: {:error, :invalid_index}

  @doc """
  Verifies a node hash and bottom-up sibling proof against a pieces root.

  `index` is relative to the proof's base layer. At each step its parity
  determines whether the current hash is the left or right child.
  """
  @spec verify(hash(), non_neg_integer(), hash(), [hash()]) :: boolean()
  def verify(root, index, hash, proof_layers)
      when is_binary(root) and is_integer(index) and index >= 0 and is_binary(hash) and
             is_list(proof_layers) do
    if valid_hash?(root) and valid_hash?(hash) and Enum.all?(proof_layers, &valid_hash?/1) do
      {computed, _index} =
        Enum.reduce(proof_layers, {hash, index}, fn sibling, {current, node_index} ->
          parent =
            if rem(node_index, 2) == 0,
              do: hash_pair(current, sibling),
              else: hash_pair(sibling, current)

          {parent, div(node_index, 2)}
        end)

      computed == root
    else
      false
    end
  end

  def verify(_root, _index, _hash, _proof_layers), do: false

  @doc """
  Validates a BEP 52 hash request against a built tree.

  Returns `:ok` or `{:error, reason}` suitable for `hash_reject`.
  """
  @spec validate_hash_request(t(), non_neg_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          :ok | {:error, atom()}
  def validate_hash_request(tree, base_layer, index, length, proof_layers) do
    num_layers = merkle_num_layers(tree.block_count)

    with :ok <- validate_request_shape(base_layer, index, length, proof_layers, nil),
         true <- base_layer < length(tree.levels) || {:error, :invalid_base_layer},
         true <- proof_layers < num_layers - base_layer || {:error, :invalid_proof_layers},
         actual = node_count(tree, base_layer),
         true <- index + length <= actual || {:error, :invalid_index} do
      :ok
    end
  end

  @doc """
  Builds the concatenated hash list for a BEP 52 `hashes` response from a tree.

  Returns `{:ok, [hash()]}` ordered as base-layer digests followed by proof
  siblings bottom-up. Omits the first `log2(length)` proof layers per BEP 52.
  """
  @spec range_response(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, [hash()]} | {:error, atom()}
  def range_response(tree, base_layer, index, length, proof_layers) do
    with :ok <- validate_hash_request(tree, base_layer, index, length, proof_layers) do
      nodes = Enum.at(tree.levels, base_layer)
      base = Enum.slice(nodes, index, length)

      proofs =
        proof_siblings(tree.levels, tree.block_count, base_layer, index, length, proof_layers)

      {:ok, base ++ proofs}
    end
  end

  @doc """
  Builds a `hashes` payload from nodes already positioned at `base_layer`.

  Used for piece-layer responses backed by root-validated metadata instead of
  rebuilding the full leaf tree from disk.
  """
  @spec range_response_from_layer(
          [hash()],
          non_neg_integer(),
          hash(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: {:ok, [hash()]} | {:error, atom()}
  def range_response_from_layer(nodes, base_layer, root, index, length, proof_layers) do
    levels = upward_levels(nodes, base_layer)

    with :ok <- validate_request_shape(base_layer, index, length, proof_layers, base_layer),
         true <- index + length <= length(nodes) || {:error, :invalid_index},
         node_count = length(nodes),
         true <- proof_layers < merkle_num_layers(node_count) || {:error, :invalid_proof_layers},
         true <- List.last(levels) |> hd() == root || {:error, :root_mismatch} do
      base = Enum.slice(nodes, index, length)

      proofs = proof_siblings(levels, node_count, 0, index, length, proof_layers)
      {:ok, base ++ proofs}
    end
  end

  @doc """
  Verifies a decoded BEP 52 `hashes` payload against a pieces root.

  `hashes` is the full list (base ++ proof) in wire order.
  """
  @spec verify_hashes(
          hash(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          [hash()],
          pos_integer()
        ) :: boolean()
  def verify_hashes(root, base_layer, index, length, proof_layers, hashes, block_count)
      when is_binary(root) and is_list(hashes) and is_integer(block_count) and block_count > 0 do
    expected = expected_response_count(length, proof_layers)

    if valid_hash?(root) and length(hashes) == expected and
         Enum.all?(hashes, &valid_hash?/1) do
      {base, proofs} = Enum.split(hashes, length)
      verify_hashes_with_proofs(root, base_layer, index, length, proofs, base, block_count)
    else
      false
    end
  end

  def verify_hashes(_root, _base_layer, _index, _length, _proof_layers, _hashes, _block_count),
    do: false

  @doc "Returns the piece-layer node hash at `piece_index` in a built tree."
  @spec piece_node(t(), pos_integer(), pos_integer()) ::
          {:ok, hash()} | {:error, :invalid_piece_length | :invalid_index}
  def piece_node(%__MODULE__{} = tree, piece_length, piece_index) do
    with {:ok, layer} <- piece_layer_level(piece_length),
         blocks_per_piece = div(piece_length, @block_size),
         piece_count = ceil_div(tree.block_count, blocks_per_piece),
         true <- piece_index >= 0 and piece_index < piece_count do
      {:ok, tree.levels |> Enum.at(layer) |> Enum.at(piece_index)}
    else
      false -> {:error, :invalid_index}
      {:error, _} = err -> err
    end
  end

  @doc "Returns the number of 16 KiB leaf blocks covering `file_length` bytes."
  @spec file_block_count(non_neg_integer()) :: pos_integer()
  def file_block_count(file_length) when is_integer(file_length) and file_length > 0 do
    ceil_div(file_length, @block_size)
  end

  @doc false
  @spec log2_int(pos_integer()) :: non_neg_integer()
  def log2_int(length) when is_integer(length) and length >= 2 do
    if power_of_two?(length), do: integer_log2(length, 0), else: 0
  end

  @doc """
  libtorrent `base_tree_layers`: `merkle_num_layers(merkle_num_leafs(count)) - 1`.

  For a power-of-two `count` this is `log2(count) - 1`.
  """
  @spec base_tree_layers(pos_integer()) :: non_neg_integer()
  def base_tree_layers(length) when is_integer(length) and length >= 2 do
    max(log2_int(length) - 1, 0)
  end

  @doc "Number of proof sibling hashes appended after the base range (libtorrent `get_hashes`)."
  @spec proof_append_count(pos_integer(), non_neg_integer()) :: non_neg_integer()
  def proof_append_count(length, proof_layers)
      when is_integer(length) and length >= 2 and is_integer(proof_layers) and proof_layers >= 0 do
    max(0, proof_layers - base_tree_layers(length))
  end

  @doc "Total 32-byte digests in a `hashes` payload for the given request shape."
  @spec expected_response_count(pos_integer(), non_neg_integer()) :: non_neg_integer()
  def expected_response_count(length, proof_layers),
    do: length + proof_append_count(length, proof_layers)

  @doc "Merkle tree layer count for a file with `block_count` 16 KiB leaves."
  @spec merkle_num_layers(pos_integer()) :: pos_integer()
  def merkle_num_layers(block_count) when is_integer(block_count) and block_count > 0 do
    integer_log2(next_power_of_two(block_count), 0)
  end

  @doc false
  @spec flat_our_layer(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def flat_our_layer(flat_idx, block_count) when is_integer(flat_idx) and flat_idx >= 0 do
    num_leafs = next_power_of_two(block_count)
    max_layer = integer_log2(num_leafs, 0)
    max_layer - flat_lib_layer(flat_idx)
  end

  @doc false
  @spec collect_proof_flat_siblings(
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [non_neg_integer()]
  def collect_proof_flat_siblings(block_count, index, length, _base_layer \\ 0, proof_layers) do
    if proof_layers == 0 do
      []
    else
      start = flat_start_index(block_count, 0, index)
      base_tree = base_tree_layers(length)

      {_, acc} =
        proof_parent_fold(proof_layers, start, [], fn i, {proof_idx, acc} ->
          proof_idx = if proof_idx > 0, do: flat_parent(proof_idx), else: 0

          acc =
            if i >= base_tree and proof_idx > 0 do
              [flat_sibling(proof_idx) | acc]
            else
              acc
            end

          {proof_idx, acc}
        end)

      Enum.reverse(acc)
    end
  end

  @doc """
  Leaf block indices that must be read from disk to serve a leaf-layer request.

  Exposed for tests verifying bounded I/O.
  """
  @spec leaf_read_indices(
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: [non_neg_integer()]
  def leaf_read_indices(block_count, piece_length, index, length, proof_layers) do
    with {:ok, piece_layer} <- piece_layer_level(piece_length) do
      block_count
      |> leaf_read_index_set(piece_length, piece_layer, index, length, proof_layers)
      |> MapSet.to_list()
      |> Enum.sort()
    else
      _ -> []
    end
  end

  @doc """
  Builds a BEP 52 leaf-layer `hashes` response using bounded `:file.pread` I/O.

  Reconstructs touched piece subtrees and verifies them against `piece_hashes`
  before returning base hashes plus libtorrent-ordered proof siblings.
  """
  @spec leaf_range_response_from_disk(
          Path.t(),
          non_neg_integer(),
          [hash()],
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: {:ok, [hash()]} | {:error, term()}
  def leaf_range_response_from_disk(
        path,
        file_length,
        piece_hashes,
        piece_length,
        index,
        length,
        proof_layers
      ) do
    block_count = file_block_count(file_length)
    num_layers = merkle_num_layers(block_count)

    with :ok <- validate_request_shape(0, index, length, proof_layers, 0),
         true <- index + length <= block_count || {:error, :invalid_index},
         true <- proof_layers < num_layers || {:error, :invalid_proof_layers},
         {:ok, piece_layer} <- piece_layer_level(piece_length),
         {:ok, fd} <- :file.open(path, [:binary, :raw, :read]) do
      try do
        metadata_levels = metadata_levels(piece_hashes, piece_layer)

        indices =
          leaf_read_index_set(block_count, piece_length, piece_layer, index, length, proof_layers)

        cache = read_leaf_cache(fd, file_length, block_count, indices)

        with :ok <-
               verify_piece_subtrees(
                 cache,
                 piece_hashes,
                 piece_length,
                 block_count,
                 index,
                 length
               ) do
          base = for leaf <- index..(index + length - 1), do: Map.fetch!(cache, leaf)

          proofs =
            proof_siblings_from_disk(
              metadata_levels,
              cache,
              block_count,
              piece_layer,
              index,
              length,
              proof_layers
            )

          {:ok, base ++ proofs}
        end
      after
        :file.close(fd)
      end
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_request}
    end
  end

  @doc """
  Validates and normalizes BEP 52 `file tree` and top-level `piece layers`.

  The returned per-file `piece_hashes` is uniform for later storage and wire
  consumers: single-piece files contain their pieces root, while larger files
  contain the validated hashes decoded from the top-level piece layer.
  """
  @spec parse_metadata(map()) :: {:ok, metadata_context()} | {:error, term()}
  def parse_metadata(%{
        "info" => %{
          "file tree" => file_tree,
          "meta version" => 2,
          "piece length" => piece_length
        },
        "piece layers" => piece_layers
      })
      when is_map(file_tree) and is_map(piece_layers) do
    with {:ok, _layer} <- piece_layer_level(piece_length),
         {:ok, files} <- walk_file_tree(file_tree, []),
         :ok <- validate_piece_layer_keys(files, piece_layers, piece_length),
         {:ok, files} <- attach_piece_layers(files, piece_layers, piece_length) do
      {:ok, %{piece_length: piece_length, files: files}}
    end
  end

  def parse_metadata(%{
        "info" => %{"file tree" => _, "meta version" => 2, "piece length" => _}
      }),
      do: {:error, :missing_piece_layers}

  def parse_metadata(_), do: {:error, :missing_v2_metadata}

  @doc """
  Validates concatenated piece-layer hashes against a file's pieces root.
  """
  @spec validate_piece_layer(hash(), binary(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, atom()}
  def validate_piece_layer(root, layer_binary, file_length, piece_length)
      when is_binary(layer_binary) and is_integer(file_length) and file_length >= 0 do
    with true <- valid_hash?(root) || {:error, :invalid_root},
         {:ok, layer} <- piece_layer_level(piece_length),
         true <- file_length > piece_length || {:error, :unexpected_piece_layer},
         expected_count = ceil_div(file_length, piece_length),
         true <-
           byte_size(layer_binary) == expected_count * @hash_size ||
             {:error, :invalid_piece_layer_size},
         hashes = split_hashes(layer_binary, []),
         padding = padding_hash(layer),
         true <- root_from_nodes(hashes, padding) == root || {:error, :piece_layer_root_mismatch} do
      :ok
    end
  end

  @type stream_entry ::
          {:file, file_context(), Path.t()}
          | {:gap, pos_integer()}

  @type piece_stream_layout :: %{
          address_space_length: non_neg_integer(),
          content_length: non_neg_integer(),
          piece_count: non_neg_integer(),
          piece_lengths: [pos_integer()],
          # Cumulative end offsets in the global piece byte stream (same shape as
          # Store.all_files). Gap entries are zero-filled alignment padding that
          # never exist on disk — BEP 52 requires each file to start on a piece
          # boundary in the concatenated stream.
          all_files: [{non_neg_integer(), stream_entry()}],
          # Per global piece index: which file (if any) owns verification.
          piece_specs: [%{file: file_context(), file_piece_index: non_neg_integer()}]
        }

  @doc """
  Builds the BEP 52 pure-v2 piece byte stream from root-validated file metadata.

  Non-empty files are visited in sorted `file tree` order. Each file starts at
  the next piece-aligned offset; trailing bytes in the file's last piece are
  zero padding in the stream but not stored in the physical file. Empty files
  are skipped entirely.
  """
  @spec piece_stream_layout(metadata_context()) :: {:ok, piece_stream_layout()} | {:error, term()}
  def piece_stream_layout(%{piece_length: piece_length, files: files}) do
    with {:ok, _layer} <- piece_layer_level(piece_length) do
      {stream_end, all_files, piece_specs} = build_stream_layout(files, piece_length, 0, [], [])
      piece_count = length(piece_specs)

      # The alignment gap belongs to the piece address space, but peers only
      # transfer the file-owned prefix of each file's final piece.
      piece_lengths =
        Enum.map(piece_specs, fn %{file: file, file_piece_index: index} ->
          min(piece_length, file.length - index * piece_length)
        end)

      {:ok,
       %{
         address_space_length: stream_end,
         content_length: Enum.reduce(files, 0, &(&1.length + &2)),
         piece_count: piece_count,
         piece_lengths: piece_lengths,
         all_files: all_files,
         piece_specs: piece_specs
       }}
    end
  end

  @doc """
  Returns the expected 32-byte digest for one file-local piece index.
  """
  @spec expected_file_piece_hash(file_context(), pos_integer(), non_neg_integer()) ::
          hash() | nil
  def expected_file_piece_hash(%{piece_hashes: hashes, length: length}, piece_length, index) do
    cond do
      length == 0 -> nil
      length <= piece_length and index == 0 -> hd(hashes)
      index >= 0 and index < length(hashes) -> Enum.at(hashes, index)
      true -> nil
    end
  end

  @doc """
  Hashes the file-owned portion of a downloaded global piece using BEP 52 rules.

  `piece_bytes` is the full on-the-wire piece (file bytes at the start, then
  alignment zeros). Leaf blocks hash short final blocks without zero-filling
  the data; missing leaf slots inside the piece subtree use the 32-byte zero
  hash, not the digest of a zero-filled block.
  """
  @spec hash_file_piece_bytes(
          file_context(),
          pos_integer(),
          non_neg_integer(),
          binary()
        ) :: hash()
  def hash_file_piece_bytes(file, piece_length, file_piece_index, piece_bytes)
      when is_binary(piece_bytes) do
    blocks_per_piece = div(piece_length, @block_size)
    offset_in_file = file_piece_index * piece_length
    bytes_in_file = min(piece_length, max(file.length - offset_in_file, 0))
    file_data = binary_part(piece_bytes, 0, bytes_in_file)

    cache =
      for block_idx <- 0..(blocks_per_piece - 1),
          block_start = block_idx * @block_size,
          into: %{} do
        leaf_index = file_piece_index * blocks_per_piece + block_idx

        cond do
          block_start >= bytes_in_file ->
            {leaf_index, @zero_hash}

          true ->
            size = min(@block_size, bytes_in_file - block_start)
            <<chunk::binary-size(^size), _::binary>> = binary_part(file_data, block_start, size)
            {leaf_index, :crypto.hash(:sha256, chunk)}
        end
      end

    block_count = file_block_count(file.length)
    piece_subtree_hash(cache, block_count, blocks_per_piece, file_piece_index)
  end

  @doc """
  Verifies one pure-v2 global piece against its file's Merkle piece digest.
  """
  @spec verify_file_piece(
          file_context(),
          pos_integer(),
          non_neg_integer(),
          binary()
        ) :: boolean()
  def verify_file_piece(file, piece_length, file_piece_index, piece_bytes) do
    expected = expected_file_piece_hash(file, piece_length, file_piece_index)

    expected != nil and
      hash_file_piece_bytes(file, piece_length, file_piece_index, piece_bytes) == expected
  end

  defp build_stream_layout([], _piece_length, stream_end, all_files, piece_specs),
    do: {stream_end, all_files, piece_specs}

  defp build_stream_layout(
         [%{length: 0} = file | rest],
         piece_length,
         stream_end,
         all_files,
         specs
       ) do
    entry = {stream_end, {:file, file, Path.join(file.path)}}
    build_stream_layout(rest, piece_length, stream_end, all_files ++ [entry], specs)
  end

  defp build_stream_layout([file | rest], piece_length, stream_end, all_files, specs) do
    aligned_start = align_stream_offset(stream_end, piece_length)
    gap = aligned_start - stream_end

    {all_files, aligned_start} =
      if gap > 0 do
        {all_files ++ [{aligned_start, {:gap, gap}}], aligned_start}
      else
        {all_files, stream_end}
      end

    file_end = aligned_start + file.length
    padded_end = aligned_start + ceil_div(file.length, piece_length) * piece_length
    gap_after = padded_end - file_end

    all_files =
      all_files ++
        [{file_end, {:file, file, Path.join(file.path)}}] ++
        if(gap_after > 0, do: [{padded_end, {:gap, gap_after}}], else: [])

    file_piece_count = ceil_div(file.length, piece_length)

    specs =
      specs ++
        for file_piece_index <- 0..(file_piece_count - 1) do
          %{file: file, file_piece_index: file_piece_index}
        end

    build_stream_layout(rest, piece_length, padded_end, all_files, specs)
  end

  defp align_stream_offset(offset, piece_length) do
    rem = rem(offset, piece_length)

    if rem == 0, do: offset, else: offset + (piece_length - rem)
  end

  @doc """
  Returns the zero-padding hash at a tree layer.

  Layer zero is 32 zero bytes. Every higher layer hashes the previous padding
  value with itself.
  """
  @spec padding_hash(non_neg_integer()) :: hash()
  def padding_hash(layer) when is_integer(layer) and layer >= 0 do
    Enum.reduce(1..layer//1, @zero_hash, fn _, hash -> hash_pair(hash, hash) end)
  end

  defp hash_blocks(<<>>, acc), do: Enum.reverse(acc)

  defp hash_blocks(content, acc) do
    size = min(byte_size(content), @block_size)
    <<block::binary-size(^size), rest::binary>> = content
    hash_blocks(rest, [:crypto.hash(:sha256, block) | acc])
  end

  defp build_levels([[_root] | _] = levels), do: Enum.reverse(levels)

  defp build_levels([current | _] = levels) do
    parents =
      current
      |> Enum.chunk_every(2)
      |> Enum.map(fn [left, right] -> hash_pair(left, right) end)

    build_levels([parents | levels])
  end

  defp hash_pair(left, right), do: :crypto.hash(:sha256, left <> right)

  defp root_from_nodes([root], _padding), do: root

  defp root_from_nodes(nodes, padding) do
    padded = nodes ++ List.duplicate(padding, next_power_of_two(length(nodes)) - length(nodes))

    padded
    |> Enum.chunk_every(2)
    |> Enum.map(fn [left, right] -> hash_pair(left, right) end)
    |> root_from_nodes(hash_pair(padding, padding))
  end

  @doc """
  Returns the piece-layer tree level for a torrent piece length.

  Layer zero is the 16 KiB leaf layer; the piece layer is
  `log2(piece_length / block_size)`.
  """
  @spec piece_layer_level(pos_integer()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def piece_layer_level(piece_length)
      when is_integer(piece_length) and piece_length >= @block_size and
             rem(piece_length, @block_size) == 0 do
    blocks = div(piece_length, @block_size)

    if power_of_two?(blocks),
      do: {:ok, integer_log2(blocks, 0)},
      else: {:error, :invalid_piece_length}
  end

  def piece_layer_level(_piece_length), do: {:error, :invalid_piece_length}

  defp validate_request_shape(base_layer, index, length, proof_layers, piece_layer) do
    allowed_layers =
      case piece_layer do
        nil -> [0]
        layer -> [0, layer]
      end

    cond do
      base_layer not in allowed_layers ->
        {:error, :invalid_base_layer}

      length < 2 or length > 512 or not power_of_two?(length) ->
        {:error, :invalid_length}

      rem(index, length) != 0 ->
        {:error, :invalid_index}

      index < 0 or proof_layers < 0 ->
        {:error, :invalid_index}

      true ->
        :ok
    end
  end

  defp node_count(%__MODULE__{block_count: block_count}, layer) do
    ceil_div(block_count, Integer.pow(2, layer))
  end

  # libtorrent flat Merkle heap (root at index 0, leaves at high indices).
  defp flat_layer_start(layer), do: Integer.pow(2, layer) - 1

  defp flat_lib_layer(idx) when idx >= 0, do: flat_lib_layer(idx, 1)

  defp flat_lib_layer(idx, layer) do
    if idx > Integer.pow(2, layer) - 2 do
      flat_lib_layer(idx, layer + 1)
    else
      layer - 1
    end
  end

  defp flat_parent(0), do: 0
  defp flat_parent(idx) when idx > 0, do: div(idx - 1, 2)

  defp flat_sibling(0), do: 0

  defp flat_sibling(idx) when idx > 0 do
    if rem(idx, 2) == 1, do: idx + 1, else: idx - 1
  end

  defp flat_start_index(block_count, base_layer, index) do
    num_leafs = next_power_of_two(block_count)
    max_layer = integer_log2(num_leafs, 0)
    lib_base = max_layer - base_layer
    flat_layer_start(lib_base) + index
  end

  defp flat_to_leaf_index(flat_idx, num_leafs), do: flat_idx - (num_leafs - 1)

  defp proof_siblings(levels, block_count, base_layer, index, length, proof_layers) do
    start = flat_start_index(block_count, base_layer, index)
    base_tree = base_tree_layers(length)

    {_, acc} =
      proof_parent_fold(proof_layers, start, [], fn i, {proof_idx, acc} ->
        proof_idx = if proof_idx > 0, do: flat_parent(proof_idx), else: 0

        acc =
          if i >= base_tree and proof_idx > 0 do
            sib = flat_sibling(proof_idx)
            [flat_hash_from_levels(levels, block_count, sib) | acc]
          else
            acc
          end

        {proof_idx, acc}
      end)

    Enum.reverse(acc)
  end

  defp flat_hash_from_levels(levels, block_count, flat_idx) do
    num_leafs = next_power_of_two(block_count)
    max_layer = integer_log2(num_leafs, 0)
    lib_layer = flat_lib_layer(flat_idx)
    our_layer = max_layer - lib_layer
    offset = flat_idx - flat_layer_start(lib_layer)
    layer_nodes = Enum.at(levels, our_layer, [])
    actual = ceil_div(block_count, Integer.pow(2, our_layer))

    if offset < length(layer_nodes) and offset < actual do
      Enum.at(layer_nodes, offset)
    else
      padding_hash(our_layer)
    end
  end

  defp proof_siblings_from_disk(
         metadata_levels,
         cache,
         block_count,
         piece_layer,
         index,
         length,
         proof_layers
       ) do
    if proof_layers == 0 do
      []
    else
      num_leafs = next_power_of_two(block_count)
      max_layer = integer_log2(num_leafs, 0)
      start = flat_start_index(block_count, 0, index)
      base_tree = base_tree_layers(length)

      {_, acc} =
        proof_parent_fold(proof_layers, start, [], fn i, {proof_idx, acc} ->
          proof_idx = if proof_idx > 0, do: flat_parent(proof_idx), else: 0

          acc =
            if i >= base_tree and proof_idx > 0 do
              sib = flat_sibling(proof_idx)

              hash =
                flat_hash_for_disk_response(
                  metadata_levels,
                  cache,
                  block_count,
                  max_layer,
                  piece_layer,
                  sib
                )

              [hash | acc]
            else
              acc
            end

          {proof_idx, acc}
        end)

      Enum.reverse(acc)
    end
  end

  defp flat_hash_for_disk_response(
         metadata_levels,
         cache,
         block_count,
         max_layer,
         piece_layer,
         flat_idx
       ) do
    if flat_our_layer(flat_idx, block_count) >= piece_layer do
      flat_hash_from_metadata(metadata_levels, block_count, piece_layer, flat_idx)
    else
      flat_hash_from_cache(cache, block_count, max_layer, flat_idx)
    end
  end

  defp metadata_levels(piece_hashes, piece_layer) do
    upward_levels(piece_hashes, piece_layer)
  end

  defp flat_hash_from_metadata(metadata_levels, block_count, piece_layer, flat_idx) do
    num_leafs = next_power_of_two(block_count)
    max_layer = integer_log2(num_leafs, 0)
    our_layer = flat_our_layer(flat_idx, block_count)
    meta_layer = our_layer - piece_layer
    offset = flat_idx - flat_layer_start(max_layer - our_layer)
    layer_nodes = Enum.at(metadata_levels, meta_layer, [])

    if offset < length(layer_nodes) do
      Enum.at(layer_nodes, offset)
    else
      padding_hash(piece_layer + meta_layer)
    end
  end

  defp flat_hash_from_cache(cache, block_count, max_layer, flat_idx) do
    subtree_hash_from_cache(cache, block_count, max_layer, flat_idx)
  end

  defp subtree_hash_from_cache(cache, block_count, max_layer, flat_idx) do
    lib_layer = flat_lib_layer(flat_idx)

    if lib_layer == max_layer do
      leaf = flat_to_leaf_index(flat_idx, next_power_of_two(block_count))

      cond do
        leaf < 0 or leaf >= block_count -> @zero_hash
        Map.has_key?(cache, leaf) -> Map.fetch!(cache, leaf)
        true -> @zero_hash
      end
    else
      left_child = flat_first_child(flat_idx)
      right_child = left_child + 1

      left =
        if lib_layer + 1 == max_layer do
          leaf = flat_to_leaf_index(left_child, next_power_of_two(block_count))
          Map.get(cache, leaf, @zero_hash)
        else
          subtree_hash_from_cache(cache, block_count, max_layer, left_child)
        end

      right =
        if lib_layer + 1 == max_layer do
          leaf = flat_to_leaf_index(right_child, next_power_of_two(block_count))
          Map.get(cache, leaf, @zero_hash)
        else
          subtree_hash_from_cache(cache, block_count, max_layer, right_child)
        end

      hash_pair(left, right)
    end
  end

  defp flat_first_child(flat_idx), do: flat_idx * 2 + 1

  defp verify_hashes_with_proofs(root, base_layer, index, length, proofs, base, block_count) do
    start = flat_start_index(block_count, base_layer, index)
    leaf_count = next_power_of_two(length)
    base_num_layers = merkle_num_layers(leaf_count)
    insert_root_idx = Bitwise.bsr(start, base_num_layers)
    subtree_root = subtree_root_from_base(base, length, leaf_count)

    if insert_root_idx == 0 and subtree_root == root do
      true
    else
      tree = %{0 => root}
      validate_and_insert_proofs(tree, insert_root_idx, subtree_root, proofs)
    end
  end

  defp subtree_root_from_base(base, length, leaf_count) do
    padded =
      base ++ List.duplicate(@zero_hash, leaf_count - length)

    padded
    |> then(&build_levels([&1]))
    |> List.last()
    |> hd()
  end

  defp validate_and_insert_proofs(tree, target_idx, node, proofs) do
    existing = Map.get(tree, target_idx, @zero_hash)

    if existing != @zero_hash and existing != node do
      false
    else
      tree = Map.put(tree, target_idx, node)
      cursor = target_idx

      result =
        Enum.reduce_while(proofs, {tree, cursor, false}, fn proof, {tree, cursor, _done} ->
          if cursor == 0 do
            {:halt, {tree, cursor, false}}
          else
            sib_idx = flat_sibling(cursor)
            sib_existing = Map.get(tree, sib_idx, @zero_hash)

            tree =
              cond do
                sib_existing == @zero_hash ->
                  Map.put(tree, sib_idx, proof)

                sib_existing == proof ->
                  tree

                true ->
                  nil
              end

            if tree == nil do
              {:halt, {tree, cursor, false}}
            else
              left = min(sib_idx, cursor)
              parent_hash = hash_pair(Map.fetch!(tree, left), Map.fetch!(tree, left + 1))
              cursor = flat_parent(cursor)
              known = Map.get(tree, cursor, @zero_hash)

              cond do
                known == parent_hash ->
                  {:halt, {tree, cursor, true}}

                known != @zero_hash ->
                  {:halt, {tree, cursor, false}}

                true ->
                  {:cont, {Map.put(tree, cursor, parent_hash), cursor, false}}
              end
            end
          end
        end)

      case result do
        {_tree, _cursor, true} -> true
        _ -> false
      end
    end
  end

  defp upward_levels(nodes, start_layer) do
    padded =
      nodes ++
        List.duplicate(
          padding_hash(start_layer),
          next_power_of_two(length(nodes)) - length(nodes)
        )

    build_upward([padded])
  end

  defp build_upward([[_root] | _] = levels), do: Enum.reverse(levels)

  defp build_upward([current | _] = levels) do
    parents =
      current
      |> Enum.chunk_every(2)
      |> Enum.map(fn [left, right] -> hash_pair(left, right) end)

    build_upward([parents | levels])
  end

  defp proof_parent_fold(0, start, acc, _fun), do: {start, acc}

  defp proof_parent_fold(proof_layers, start, acc, fun) when proof_layers > 0 do
    Enum.reduce(0..(proof_layers - 1), {start, acc}, fun)
  end

  defp proof_sibling_leaf_indices(
         block_count,
         _piece_length,
         piece_layer,
         index,
         length,
         proof_layers
       ) do
    collect_proof_flat_siblings(block_count, index, length, 0, proof_layers)
    |> Enum.flat_map(fn flat_idx ->
      if flat_our_layer(flat_idx, block_count) >= piece_layer do
        []
      else
        leaf_indices_for_flat_node(flat_idx, block_count)
      end
    end)
  end

  defp leaf_indices_for_flat_node(flat_idx, block_count) do
    our_layer = flat_our_layer(flat_idx, block_count)
    span = Integer.pow(2, our_layer)
    num_leafs = next_power_of_two(block_count)
    max_layer = integer_log2(num_leafs, 0)
    node_offset = flat_idx - flat_layer_start(max_layer - our_layer)
    first = node_offset * span
    last = min(first + span - 1, block_count - 1)

    if first <= last, do: Enum.to_list(first..last), else: []
  end

  defp leaf_read_index_set(block_count, piece_length, piece_layer, index, length, proof_layers) do
    blocks_per_piece = div(piece_length, @block_size)
    first_piece = div(index, blocks_per_piece)
    last_piece = div(index + length - 1, blocks_per_piece)

    piece_indices =
      for piece <- first_piece..last_piece,
          leaf <-
            (piece * blocks_per_piece)..min((piece + 1) * blocks_per_piece - 1, block_count - 1),
          into: MapSet.new(),
          do: leaf

    proof_indices =
      proof_sibling_leaf_indices(
        block_count,
        piece_length,
        piece_layer,
        index,
        length,
        proof_layers
      )
      |> MapSet.new()

    MapSet.new(index..(index + length - 1))
    |> MapSet.union(proof_indices)
    |> MapSet.union(piece_indices)
    |> MapSet.filter(&(&1 < block_count))
  end

  defp read_leaf_cache(fd, file_length, block_count, indices) do
    Enum.reduce(indices, %{}, fn leaf, acc ->
      Map.put(acc, leaf, leaf_hash_from_fd(fd, file_length, block_count, leaf))
    end)
  end

  defp leaf_hash_from_fd(fd, file_length, block_count, leaf_index) do
    offset = leaf_index * @block_size

    data =
      cond do
        offset >= file_length ->
          <<>>

        offset + @block_size > file_length ->
          size = file_length - offset
          {:ok, block} = :file.pread(fd, offset, size)
          block

        true ->
          {:ok, block} = :file.pread(fd, offset, @block_size)
          block
      end

    cond do
      leaf_index >= block_count -> @zero_hash
      byte_size(data) == 0 -> @zero_hash
      true -> :crypto.hash(:sha256, data)
    end
  end

  defp subtree_hash(cache, block_count, layer, node_index) do
    if layer == 0 do
      if node_index < block_count do
        Map.get(cache, node_index, @zero_hash)
      else
        @zero_hash
      end
    else
      left = subtree_hash(cache, block_count, layer - 1, node_index * 2)
      right = subtree_hash(cache, block_count, layer - 1, node_index * 2 + 1)
      hash_pair(left, right)
    end
  end

  defp verify_piece_subtrees(cache, piece_hashes, piece_length, block_count, index, length) do
    blocks_per_piece = div(piece_length, @block_size)
    first_piece = div(index, blocks_per_piece)
    last_piece = div(index + length - 1, blocks_per_piece)

    if Enum.all?(first_piece..last_piece, fn piece_idx ->
         computed = piece_subtree_hash(cache, block_count, blocks_per_piece, piece_idx)
         Enum.at(piece_hashes, piece_idx) == computed
       end) do
      :ok
    else
      {:error, :piece_mismatch}
    end
  end

  defp piece_subtree_hash(cache, block_count, blocks_per_piece, piece_idx) do
    if blocks_per_piece == 1 do
      if piece_idx < block_count do
        Map.get(cache, piece_idx, @zero_hash)
      else
        @zero_hash
      end
    else
      layer = log2_int(blocks_per_piece)
      subtree_hash(cache, block_count, layer, piece_idx)
    end
  end

  defp integer_log2(1, acc), do: acc
  defp integer_log2(value, acc), do: integer_log2(div(value, 2), acc + 1)

  defp next_power_of_two(value), do: next_power_of_two(value, 1)
  defp next_power_of_two(value, power) when power >= value, do: power
  defp next_power_of_two(value, power), do: next_power_of_two(value, power * 2)

  defp power_of_two?(value), do: value > 0 and Bitwise.band(value, value - 1) == 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
  defp valid_hash?(hash), do: is_binary(hash) and byte_size(hash) == @hash_size

  defp walk_file_tree(node, path) when is_map(node) do
    case Map.fetch(node, "") do
      {:ok, properties} ->
        parse_file_properties(properties, path, map_size(node))

      :error ->
        node
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, []}, fn {component, child}, {:ok, files} ->
          case walk_file_tree(child, path ++ [component]) do
            {:ok, child_files} -> {:cont, {:ok, files ++ child_files}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp walk_file_tree(_node, _path), do: {:error, :invalid_file_tree}

  defp parse_file_properties(%{"length" => length} = properties, path, 1)
       when is_integer(length) and length >= 0 and path != [] do
    root = Map.get(properties, "pieces root")

    cond do
      length == 0 and is_nil(root) ->
        {:ok, [%{path: path, length: 0, pieces_root: nil, piece_hashes: []}]}

      length > 0 and valid_hash?(root) ->
        {:ok, [%{path: path, length: length, pieces_root: root, piece_hashes: []}]}

      true ->
        {:error, :invalid_pieces_root}
    end
  end

  defp parse_file_properties(_properties, _path, _entry_count), do: {:error, :invalid_file_tree}

  defp attach_piece_layers(files, piece_layers, piece_length) when is_map(piece_layers) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case attach_piece_layer(file, piece_layers, piece_length) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp validate_piece_layer_keys(files, piece_layers, piece_length) do
    expected =
      files
      |> Enum.filter(&(&1.length > piece_length))
      |> MapSet.new(& &1.pieces_root)

    actual = piece_layers |> Map.keys() |> MapSet.new()

    if actual == expected, do: :ok, else: {:error, :invalid_piece_layer_keys}
  end

  defp attach_piece_layer(%{length: 0} = file, _piece_layers, _piece_length),
    do: {:ok, file}

  defp attach_piece_layer(
         %{length: length, pieces_root: root} = file,
         _piece_layers,
         piece_length
       )
       when length <= piece_length,
       do: {:ok, %{file | piece_hashes: [root]}}

  defp attach_piece_layer(%{length: length, pieces_root: root} = file, piece_layers, piece_length) do
    case Map.fetch(piece_layers, root) do
      {:ok, layer_binary} ->
        with :ok <- validate_piece_layer(root, layer_binary, length, piece_length) do
          {:ok, %{file | piece_hashes: split_hashes(layer_binary, [])}}
        end

      :error ->
        {:error, :missing_piece_layer}
    end
  end

  defp split_hashes(<<>>, acc), do: Enum.reverse(acc)

  defp split_hashes(<<hash::binary-size(@hash_size), rest::binary>>, acc),
    do: split_hashes(rest, [hash | acc])
end

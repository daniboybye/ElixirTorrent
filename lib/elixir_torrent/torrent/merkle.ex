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

  defp piece_layer_level(piece_length)
       when is_integer(piece_length) and piece_length >= @block_size and
              rem(piece_length, @block_size) == 0 do
    blocks = div(piece_length, @block_size)

    if power_of_two?(blocks),
      do: {:ok, integer_log2(blocks, 0)},
      else: {:error, :invalid_piece_length}
  end

  defp piece_layer_level(_piece_length), do: {:error, :invalid_piece_length}

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

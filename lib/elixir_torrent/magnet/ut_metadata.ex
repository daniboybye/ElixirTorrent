defmodule Magnet.UtMetadata do
  @moduledoc """
  BEP 9 (`ut_metadata`) helpers — message encoding/decoding, piece math, and verification.

  Metadata is transferred in 16 KiB blocks (BEP 9 § metadata). Extension negotiation uses
  BEP 10: peers advertise `ut_metadata` in the handshake `m` dictionary and, when they
  already hold the torrent metadata, include top-level `metadata_size` (BEP 9 § extension header).
  """

  @block_size 16_384
  # The bencoded data header is normally under 100 bytes. Keep a small bounded
  # allowance for key ordering / integer widths while rejecting a declared
  # ut_metadata frame before Peer.Sender buffers an attacker-sized body.
  @max_header_size 1_024

  @type msg_type :: :request | :data | :reject
  @type extension_handshake :: %{
          optional(:ut_metadata_id) => pos_integer() | nil,
          optional(:metadata_size) => pos_integer() | nil
        }

  alias Magnet.UtMetadata.Extension
  alias Peer.LTEP.Handshake

  @doc """
  Fixed metadata block size from BEP 9 (16384 bytes).
  """
  @spec block_size() :: pos_integer()
  def block_size, do: @block_size

  @doc false
  @spec max_message_payload_size() :: pos_integer()
  def max_message_payload_size, do: @block_size + @max_header_size

  @doc """
  Number of metadata pieces for a given total metadata byte size.

  All pieces are 16 KiB except possibly the last (BEP 9 § metadata).
  """
  @spec piece_count(pos_integer()) :: pos_integer()
  def piece_count(metadata_size) when is_integer(metadata_size) and metadata_size > 0 do
    div(metadata_size + @block_size - 1, @block_size)
  end

  @doc """
  Expected byte length of a metadata piece index for a given total size.
  """
  @spec piece_byte_size(pos_integer(), non_neg_integer()) :: pos_integer()
  def piece_byte_size(metadata_size, piece_index)
      when is_integer(metadata_size) and metadata_size > 0 and is_integer(piece_index) and
             piece_index >= 0 do
    start = piece_index * @block_size
    remaining = metadata_size - start
    min(@block_size, remaining)
  end

  @doc """
  Parses a peer's BEP 10 extension handshake for BEP 9 fields.

  Prefer `Peer.LTEP.Handshake` for full BEP 10 parsing; this helper extracts only
  `ut_metadata` id and `metadata_size` for tests and callers that still use raw maps.
  """
  @spec parse_extension_handshake(map() | Handshake.t()) :: extension_handshake()
  def parse_extension_handshake(%Handshake{} = hs) do
    parse_extension_handshake(Handshake.to_map(hs))
  end

  def parse_extension_handshake(handshake) when is_map(handshake) do
    hs = Handshake.from_map(handshake)

    %{
      ut_metadata_id: Handshake.peer_extension_id(hs, Extension.name()),
      metadata_size: hs.metadata_size
    }
  end

  @doc false
  def extension_name, do: Extension.name()

  @doc """
  Encodes a BEP 9 data message (`msg_type` 1) with raw bytes appended after the dictionary.
  """
  @spec encode_data(non_neg_integer(), pos_integer(), binary()) :: binary()
  def encode_data(piece_index, total_size, data)
      when is_integer(piece_index) and piece_index >= 0 and is_integer(total_size) and
             total_size > 0 and is_binary(data) do
    dict =
      Bento.encode!(%{
        "msg_type" => 1,
        "piece" => piece_index,
        "total_size" => total_size
      })

    dict <> data
  end

  @doc """
  Encodes a BEP 9 reject message (`msg_type` 2).
  """
  @spec encode_reject(non_neg_integer()) :: binary()
  def encode_reject(piece_index) when is_integer(piece_index) and piece_index >= 0 do
    Bento.encode!(%{"msg_type" => 2, "piece" => piece_index})
  end

  @doc """
  Returns one metadata piece for serving, or `:reject` when unavailable.
  """
  @spec serve_piece(Torrent.hash(), non_neg_integer()) ::
          {:ok, binary(), pos_integer()} | :reject
  def serve_piece(hash, piece_index) when is_integer(piece_index) and piece_index >= 0 do
    with blob when is_binary(blob) <- Torrent.Metadata.info_blob(hash),
         total = byte_size(blob),
         true <- piece_index < piece_count(total) do
      start = piece_index * @block_size
      size = piece_byte_size(total, piece_index)
      {:ok, binary_part(blob, start, size), total}
    else
      _ -> :reject
    end
  end

  @doc """
  Encodes a BEP 9 request message (`msg_type` 0).
  """
  @spec encode_request(non_neg_integer()) :: binary()
  def encode_request(piece_index) when is_integer(piece_index) and piece_index >= 0 do
    Bento.encode!(%{"msg_type" => 0, "piece" => piece_index})
  end

  @doc """
  Decodes a BEP 9 extension message payload.

  Data messages append raw bytes after the bencoded dictionary (BEP 9 § data); this function
  splits the prefix and returns the trailing binary as `data`.
  """
  @spec decode_message(binary()) ::
          {:ok, {msg_type(), keyword()}} | {:error, term()}
  def decode_message(payload) when is_binary(payload) do
    with {:ok, dict, rest} <- split_bencoded_prefix(payload),
         {:ok, msg_type, piece} <- parse_common_fields(dict) do
      case msg_type do
        :request ->
          decode_trailing_free_message(:request, piece, rest)

        :reject ->
          decode_trailing_free_message(:reject, piece, rest)

        :data ->
          decode_data_message(dict, rest, piece)
      end
    end
  end

  @spec decode_trailing_free_message(msg_type(), non_neg_integer(), binary()) ::
          {:ok, {msg_type(), keyword()}} | {:error, term()}
  defp decode_trailing_free_message(kind, piece, rest) do
    if rest == "" do
      {:ok, {kind, [piece: piece]}}
    else
      {:error, :trailing_data}
    end
  end

  @spec decode_data_message(map(), binary(), non_neg_integer()) ::
          {:ok, {msg_type(), keyword()}} | {:error, term()}
  defp decode_data_message(dict, rest, piece) do
    total_size = Map.get(dict, "total_size")

    cond do
      not (is_integer(total_size) and total_size > 0) ->
        {:error, :missing_total_size}

      byte_size(rest) > @block_size ->
        {:error, :piece_too_large}

      true ->
        {:ok, {:data, [piece: piece, total_size: total_size, data: rest]}}
    end
  end

  @doc """
  Joins received pieces (index => binary) into the full metadata blob.

  Returns `{:error, :incomplete}` if any piece is missing or has the wrong length.
  """
  @spec assemble_pieces(%{non_neg_integer() => binary()}, pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def assemble_pieces(pieces, metadata_size)
      when is_map(pieces) and is_integer(metadata_size) and metadata_size > 0 do
    count = piece_count(metadata_size)

    assembled =
      Enum.reduce_while(0..(count - 1), <<>>, fn index, acc ->
        expected = piece_byte_size(metadata_size, index)

        case Map.get(pieces, index) do
          bin when is_binary(bin) and byte_size(bin) == expected ->
            {:cont, acc <> bin}

          _ ->
            {:halt, :incomplete}
        end
      end)

    case assembled do
      :incomplete -> {:error, :incomplete}
      blob when byte_size(blob) == metadata_size -> {:ok, blob}
      _ -> {:error, :size_mismatch}
    end
  end

  @doc """
  Decodes assembled metadata bytes into an info dictionary and verifies SHA-1.

  BEP 9: the transferred blob is the bencoded info dictionary; its SHA-1 must equal
  the magnet info-hash (BEP 3). Returns the raw blob alongside the decoded map so
  callers can persist the exact wire bytes (see `Magnet.build_torrent!/2`).
  """
  @spec decode_and_verify_info(binary(), Torrent.hash()) ::
          {:ok, map(), binary()} | {:error, term()}
  def decode_and_verify_info(metadata_blob, expected_hash)
      when is_binary(metadata_blob) and is_binary(expected_hash) do
    hash = :crypto.hash(:sha, metadata_blob)

    if hash == expected_hash do
      case Bento.decode(metadata_blob) do
        {:ok, info} when is_map(info) -> {:ok, info, metadata_blob}
        _ -> {:error, :invalid_info}
      end
    else
      {:error, :info_hash_mismatch}
    end
  end

  @doc false
  @spec split_bencoded_prefix(binary()) :: {:ok, map(), binary()} | {:error, term()}
  def split_bencoded_prefix(payload) do
    case parse_bencode_value(payload) do
      {%{} = dict, rest} -> {:ok, dict, rest}
      {_, _} -> {:error, :expected_dictionary}
    end
  catch
    :invalid -> {:error, :invalid_bencode}
    {:invalid, _} -> {:error, :invalid_bencode}
  end

  defp parse_common_fields(%{"msg_type" => 0, "piece" => piece})
       when is_integer(piece) and piece >= 0,
       do: {:ok, :request, piece}

  defp parse_common_fields(%{"msg_type" => 1, "piece" => piece})
       when is_integer(piece) and piece >= 0,
       do: {:ok, :data, piece}

  defp parse_common_fields(%{"msg_type" => 2, "piece" => piece})
       when is_integer(piece) and piece >= 0,
       do: {:ok, :reject, piece}

  defp parse_common_fields(_), do: {:error, :invalid_message_fields}

  # Minimal bencode prefix parser (one value + rest). Mirrors Bento.Parser so we can
  # split BEP 9 data messages where raw bytes follow the dictionary.
  defp parse_bencode_value("d" <> rest), do: map_pairs(rest, [])
  defp parse_bencode_value("l" <> rest), do: list_values(rest, [])
  defp parse_bencode_value(<<c>> <> _ = str) when c in ~c"0123456789", do: string_start(str)
  defp parse_bencode_value("i" <> rest), do: integer_start(rest)
  defp parse_bencode_value(_), do: throw(:invalid)

  defp integer_start("0e" <> rest), do: {0, rest}
  defp integer_start("-e" <> _), do: throw(:invalid)
  defp integer_start("-0" <> _), do: throw(:invalid)

  defp integer_start(<<char>> <> rest) when char in ~c"-123456789",
    do: integer_continue(rest, [char])

  defp integer_start(_), do: throw(:invalid)

  defp integer_continue("e" <> rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.to_integer(), rest}

  defp integer_continue(<<digit>> <> rest, acc) when digit in ~c"0123456789",
    do: integer_continue(rest, [digit | acc])

  defp integer_continue(_, _), do: throw(:invalid)

  defp string_start("0:" <> rest), do: {"", rest}

  defp string_start(<<digit>> <> rest) when digit in ~c"123456789",
    do: string_length(rest, [digit])

  defp string_start(_), do: throw(:invalid)

  defp string_length(<<digit>> <> rest, acc) when digit in ~c"0123456789",
    do: string_length(rest, [digit | acc])

  defp string_length(":" <> rest, acc) do
    len = acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.to_integer()
    string_contents(len, rest)
  end

  defp string_length(_, _), do: throw(:invalid)

  defp string_contents(len, str) when len > byte_size(str), do: throw(:invalid)

  defp string_contents(len, str) do
    {binary_part(str, 0, len), binary_part(str, len, byte_size(str) - len)}
  end

  defp list_values("e" <> rest, []), do: {[], rest}

  defp list_values(str, acc) do
    {value, rest} = parse_bencode_value(str)
    acc = [value | acc]

    case rest do
      "e" <> rest -> {Enum.reverse(acc), rest}
      "" -> throw(:invalid)
      rest -> list_values(rest, acc)
    end
  end

  defp map_pairs("e" <> rest, []), do: {%{}, rest}

  defp map_pairs(str, acc) do
    {name, rest} = string_start(str)
    {value, rest} = parse_bencode_value(rest)
    acc = [{name, value} | acc]

    case rest do
      "e" <> rest -> {Map.new(acc), rest}
      "" -> throw(:invalid)
      rest -> map_pairs(rest, acc)
    end
  end
end

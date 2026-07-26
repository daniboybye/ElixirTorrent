defmodule Peer.HashWire do
  @moduledoc """
  BEP 52 hash transfer wire payloads (message ids 21–23, not LTEP).

  Header layout (48 bytes): `pieces_root` (32) + `base_layer`, `index`, `length`,
  and `proof_layers` as unsigned 32-bit big-endian fields. `hashes` appends 32-byte
  digests after the header; `hash_reject` echoes the request header exactly.
  """

  @hash_size 32
  @header_size 48
  @max_length 512
  @max_proof_hashes 64

  @enforce_keys [:pieces_root, :base_layer, :index, :length, :proof_layers]
  defstruct [:pieces_root, :base_layer, :index, :length, :proof_layers]

  @type t :: %__MODULE__{
          pieces_root: Torrent.Merkle.hash(),
          base_layer: non_neg_integer(),
          index: non_neg_integer(),
          length: pos_integer(),
          proof_layers: non_neg_integer()
        }

  @doc "Fixed header size for hash_request / hashes / hash_reject."
  @spec header_size() :: pos_integer()
  def header_size, do: @header_size

  @doc false
  @spec max_hashes_message_size() :: pos_integer()
  def max_hashes_message_size do
    1 + @header_size + (@max_length + @max_proof_hashes) * @hash_size
  end

  @doc "Encodes the shared 48-byte request header."
  @spec encode_header(t()) :: binary()
  def encode_header(%__MODULE__{} = req) do
    <<
      req.pieces_root::binary-size(@hash_size),
      req.base_layer::32,
      req.index::32,
      req.length::32,
      req.proof_layers::32
    >>
  end

  @doc "Encodes a BEP 52 `hash_request` message body (id 21, excluding length prefix)."
  @spec encode_request(t()) :: binary()
  def encode_request(%__MODULE__{} = req), do: encode_header(req)

  @doc "Encodes a BEP 52 `hash_reject` message body (id 23)."
  @spec encode_reject(t()) :: binary()
  def encode_reject(%__MODULE__{} = req), do: encode_header(req)

  @doc "Encodes a BEP 52 `hashes` message body (id 22)."
  @spec encode_hashes(t(), iodata()) :: binary()
  def encode_hashes(%__MODULE__{} = req, hashes) do
    IO.iodata_to_binary([encode_header(req), hashes])
  end

  @doc "Decodes the 48-byte header shared by all three message types."
  @spec decode_header(binary()) :: {:ok, t()} | {:error, :truncated}
  def decode_header(header) when byte_size(header) >= @header_size do
    <<
      pieces_root::binary-size(@hash_size),
      base_layer::32,
      index::32,
      length::32,
      proof_layers::32,
      _rest::binary
    >> = header

    {:ok,
     %__MODULE__{
       pieces_root: pieces_root,
       base_layer: base_layer,
       index: index,
       length: length,
       proof_layers: proof_layers
     }}
  end

  def decode_header(_), do: {:error, :truncated}

  @doc "Decodes a `hash_request` or `hash_reject` body (must be exactly 48 bytes)."
  @spec decode_request(binary()) :: {:ok, t()} | {:error, :truncated | :invalid_size}
  def decode_request(body) when byte_size(body) == @header_size, do: decode_header(body)
  def decode_request(body) when byte_size(body) < @header_size, do: {:error, :truncated}
  def decode_request(_), do: {:error, :invalid_size}

  @doc "Decodes a `hashes` body (48-byte header + trailing 32-byte digests)."
  @spec decode_hashes(binary()) :: {:ok, t(), binary()} | {:error, term()}
  def decode_hashes(body) when byte_size(body) >= @header_size do
    <<header::binary-size(@header_size), hashes::binary>> = body

    if rem(byte_size(hashes), @hash_size) != 0 do
      {:error, :invalid_hashes_size}
    else
      case decode_header(header) do
        {:ok, req} -> {:ok, req, hashes}
        error -> error
      end
    end
  end

  def decode_hashes(body) when byte_size(body) < @header_size, do: {:error, :truncated}

  @doc """
  Validates syntactic BEP 52 hash-request constraints.

  Semantic checks (known pieces root, v2 context, disk completeness) belong in
  `Torrent.HashServe` and yield `hash_reject`, not errors here.
  """
  @spec validate_request(t(), pos_integer()) :: :ok | {:error, atom()}
  def validate_request(%__MODULE__{} = req, piece_layer) do
    cond do
      not valid_root?(req.pieces_root) ->
        {:error, :invalid_root}

      req.base_layer not in [0, piece_layer] ->
        {:error, :invalid_base_layer}

      req.length < 2 or req.length > @max_length or not power_of_two?(req.length) ->
        {:error, :invalid_length}

      rem(req.index, req.length) != 0 ->
        {:error, :invalid_index}

      req.index < 0 ->
        {:error, :invalid_index}

      true ->
        :ok
    end
  end

  @doc "Number of 32-byte digests appended after the header in a `hashes` message."
  @spec expected_hash_count(t()) :: non_neg_integer()
  def expected_hash_count(%__MODULE__{length: length, proof_layers: proof_layers}) do
    length + Torrent.Merkle.proof_append_count(length, proof_layers)
  end

  @doc "Validates a `hashes` payload has the exact trailing byte size for `req`."
  @spec validate_hashes_payload(t(), binary()) :: :ok | {:error, atom()}
  def validate_hashes_payload(%__MODULE__{} = req, hashes_binary) when is_binary(hashes_binary) do
    expected_bytes = expected_hash_count(req) * @hash_size

    cond do
      rem(byte_size(hashes_binary), @hash_size) != 0 ->
        {:error, :invalid_hashes_size}

      byte_size(hashes_binary) != expected_bytes ->
        {:error, :hash_count_mismatch}

      true ->
        :ok
    end
  end

  @doc "Splits the trailing digest blob; size must match `expected_hash_count/1`."
  @spec split_hashes(t(), binary()) ::
          {:ok, {[Torrent.Merkle.hash()], [Torrent.Merkle.hash()]}}
          | {:error, atom()}
  def split_hashes(%__MODULE__{} = req, hashes_binary) do
    with :ok <- validate_hashes_payload(req, hashes_binary) do
      all = for <<hash::binary-size(@hash_size) <- hashes_binary>>, do: hash
      {base, proof} = Enum.split(all, req.length)
      {:ok, {base, proof}}
    end
  end

  @doc """
  Validates header semantics shared by `hashes` and `hash_reject` responses.
  """
  @spec validate_response_header(t(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def validate_response_header(%__MODULE__{} = req, piece_layer, num_layers) do
    with :ok <- validate_request(req, piece_layer) do
      validate_proof_depth(req, num_layers)
    end
  end

  @spec validate_proof_depth(t(), non_neg_integer()) :: :ok | {:error, atom()}
  defp validate_proof_depth(%__MODULE__{base_layer: base, proof_layers: proof_layers}, num_layers) do
    if is_integer(proof_layers) and proof_layers >= 0 and proof_layers < num_layers - base do
      :ok
    else
      {:error, :invalid_proof_layers}
    end
  end

  defp valid_root?(<<_::256>>), do: true
  defp valid_root?(_), do: false

  defp power_of_two?(value), do: value > 0 and Bitwise.band(value, value - 1) == 0
end

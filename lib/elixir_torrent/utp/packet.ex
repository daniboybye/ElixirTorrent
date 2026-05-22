defmodule UTP.Packet do
  @moduledoc """
  BEP 29 uTP packet header codec (version 1).

  Header layout (20 bytes, big-endian):

      type(4) | ver(4) | ext(8) | conn_id(16) | timestamp_us(32) |
      timestamp_diff_us(32) | wnd_size(32) | seq_nr(16) | ack_nr(16)
  """

  @version 1

  @st_data 0
  @st_fin 1
  @st_state 2
  @st_reset 3
  @st_syn 4

  @ext_selective_ack 1

  @header_size 20

  defstruct [
    :type,
    :version,
    :extension,
    :conn_id,
    :timestamp,
    :timestamp_difference,
    :wnd_size,
    :seq_nr,
    :ack_nr,
    extensions: []
  ]

  @type t :: %__MODULE__{
          type: 0..4,
          version: 1,
          extension: byte(),
          conn_id: 0..65_535,
          timestamp: non_neg_integer(),
          timestamp_difference: non_neg_integer(),
          wnd_size: non_neg_integer(),
          seq_nr: 0..65_535,
          ack_nr: 0..65_535,
          extensions: [extension()]
        }

  @type extension :: {:selective_ack, bitmask :: binary()}

  @type decode_error :: :too_short | :bad_version | :truncated_extension

  @doc false
  @spec st_data() :: 0
  def st_data, do: @st_data

  @doc false
  @spec st_fin() :: 1
  def st_fin, do: @st_fin

  @doc false
  @spec st_state() :: 2
  def st_state, do: @st_state

  @doc false
  @spec st_reset() :: 3
  def st_reset, do: @st_reset

  @doc false
  @spec st_syn() :: 4
  def st_syn, do: @st_syn

  @doc false
  @spec header_size() :: 20
  def header_size, do: @header_size

  @doc """
  Returns true when `data` looks like a uTP v1 packet (not DHT/KRPC bencode).
  """
  @spec utp_packet?(binary()) :: boolean()
  def utp_packet?(<<byte, _::binary>>) do
    version(byte) == @version and type(byte) in 0..4
  end

  def utp_packet?(_), do: false

  @spec encode(t(), iodata()) :: binary()
  def encode(%__MODULE__{} = header, payload \\ <<>>) do
    {ext_type, ext_body} = encode_extensions(header.extensions)

    header_bytes =
      <<
        type_and_version(header.type, header.version),
        ext_type,
        header.conn_id::16,
        header.timestamp::32,
        header.timestamp_difference::32,
        header.wnd_size::32,
        header.seq_nr::16,
        header.ack_nr::16
      >>

    IO.iodata_to_binary([header_bytes, ext_body, payload])
  end

  @spec decode(binary()) :: {:ok, t(), binary(), [extension()]} | {:error, decode_error()}
  def decode(data) when byte_size(data) >= @header_size do
    {type_ver, extension, conn_id, timestamp, timestamp_diff, wnd_size, seq_nr, ack_nr, rest} =
      parse_header_bytes(data)

    with {:ok, version} <- version_ok(type_ver),
         {:ok, extensions, payload} <- decode_extensions(extension, rest) do
      header =
        build_header(
          {type_ver, extension, conn_id, timestamp, timestamp_diff, wnd_size, seq_nr, ack_nr},
          version,
          extensions
        )

      {:ok, header, payload, extensions}
    end
  end

  def decode(_), do: {:error, :too_short}

  @spec parse_header_bytes(binary()) ::
          {byte(), byte(), 0..65_535, 0..4_294_967_295, 0..4_294_967_295, 0..4_294_967_295,
           0..65_535, 0..65_535, binary()}
  defp parse_header_bytes(data) do
    <<
      type_ver,
      extension,
      conn_id::16,
      timestamp::32,
      timestamp_diff::32,
      wnd_size::32,
      seq_nr::16,
      ack_nr::16
    >> = binary_part(data, 0, @header_size)

    rest = binary_part(data, @header_size, byte_size(data) - @header_size)

    {type_ver, extension, conn_id, timestamp, timestamp_diff, wnd_size, seq_nr, ack_nr, rest}
  end

  @type parsed_header :: {
          byte(),
          byte(),
          0..65_535,
          0..4_294_967_295,
          0..4_294_967_295,
          0..4_294_967_295,
          0..65_535,
          0..65_535
        }

  @spec build_header(parsed_header(), byte(), [extension()]) :: t()
  defp build_header(
         {type_ver, extension, conn_id, timestamp, timestamp_diff, wnd_size, seq_nr, ack_nr},
         version,
         extensions
       ) do
    %__MODULE__{
      type: type(type_ver),
      version: version,
      extension: extension,
      conn_id: conn_id,
      timestamp: timestamp,
      timestamp_difference: timestamp_diff,
      wnd_size: wnd_size,
      seq_nr: seq_nr,
      ack_nr: ack_nr,
      extensions: extensions
    }
  end

  @spec selective_ack_acks(t(), [extension()]) :: [0..65_535]
  def selective_ack_acks(%__MODULE__{ack_nr: ack_nr}, extensions) do
    extensions
    |> Enum.filter(&match?({:selective_ack, _}, &1))
    |> Enum.flat_map(fn {:selective_ack, bitmask} ->
      parse_selective_ack(ack_nr, bitmask)
    end)
  end

  @spec parse_selective_ack(0..65_535, binary()) :: [0..65_535]
  def parse_selective_ack(ack_nr, bitmask) when is_binary(bitmask) do
    bitmask
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {byte, byte_idx} ->
      sack_byte_seqs(ack_nr, byte, byte_idx)
    end)
  end

  defp sack_byte_seqs(ack_nr, byte, byte_idx) do
    Enum.flat_map(0..7, fn bit_idx ->
      if Bitwise.band(byte, Bitwise.bsl(1, bit_idx)) != 0 do
        [seq_add(ack_nr, 2 + byte_idx * 8 + bit_idx)]
      else
        []
      end
    end)
  end

  @spec seq_add(0..65_535, integer()) :: 0..65_535
  def seq_add(seq, delta), do: rem(seq + delta + 65_536, 65_536)

  @spec seq_diff(0..65_535, 0..65_535) :: integer()
  def seq_diff(a, b), do: rem(a - b + 32_768, 65_536) - 32_768

  @spec seq_before?(0..65_535, 0..65_535) :: boolean()
  def seq_before?(a, b), do: seq_diff(a, b) < 0

  @spec seq_after?(0..65_535, 0..65_535) :: boolean()
  def seq_after?(a, b), do: seq_diff(a, b) > 0

  @spec seq_between?(0..65_535, 0..65_535, 0..65_535) :: boolean()
  def seq_between?(seq, low, high) do
    seq_diff(seq, low) >= 0 and seq_diff(high, seq) >= 0
  end

  defp type_and_version(type, version) do
    Bitwise.bor(Bitwise.bsl(type, 4), Bitwise.band(version, 0x0F))
  end

  defp type(type_ver), do: Bitwise.bsr(type_ver, 4)
  defp version(type_ver), do: Bitwise.band(type_ver, 0x0F)

  defp version_ok(type_ver) do
    case version(type_ver) do
      @version -> {:ok, @version}
      _ -> {:error, :bad_version}
    end
  end

  defp encode_extensions([]), do: {0, <<>>}

  defp encode_extensions([{:selective_ack, bitmask} | rest]) do
    {next_type, _next_body} = encode_extensions(rest)
    body = <<next_type, byte_size(bitmask), bitmask::binary>>
    {@ext_selective_ack, body}
  end

  defp decode_extensions(0, rest), do: {:ok, [], rest}

  defp decode_extensions(ext_type, rest) do
    with <<next_ext, len, ext_body::binary-size(len), tail::binary>> <- rest,
         {:ok, inner, payload} <- decode_extensions(next_ext, tail) do
      ext =
        case ext_type do
          @ext_selective_ack -> {:selective_ack, ext_body}
          _ -> nil
        end

      extensions = if ext, do: [ext | inner], else: inner
      {:ok, extensions, payload}
    else
      _ -> {:error, :truncated_extension}
    end
  end
end

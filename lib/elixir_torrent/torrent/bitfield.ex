defmodule Torrent.Bitfield do
  @spec make(pos_integer()) :: binary()
  def make(count) do
    count
    |> expected_byte_size()
    |> (&List.duplicate(0, &1)).()
    |> :binary.list_to_bin()
  end

  @doc """
  Expected bitfield byte length for `pieces_count` piece indices (BEP 3 bitfield).
  """
  @spec expected_byte_size(pos_integer()) :: pos_integer()
  def expected_byte_size(pieces_count), do: size(pieces_count)

  @doc """
  Returns whether `bitfield` has the correct byte length for `pieces_count` indices.
  """
  @spec valid?(binary(), pos_integer()) :: boolean()
  def valid?(bitfield, pieces_count)
      when is_binary(bitfield) and is_integer(pieces_count) and pieces_count > 0 do
    byte_size(bitfield) == expected_byte_size(pieces_count)
  end

  def valid?(_, _), do: false

  @spec set(binary(), non_neg_integer(), 0 | 1) :: binary()
  def set(bitfield, index, x) do
    <<prefix::bits-size(^index), _::1, postfix::bits>> = bitfield
    <<prefix::bits, x::1, postfix::bits>>
  end

  @spec have?(binary(), non_neg_integer()) :: boolean()
  def have?(bitfield, index) do
    <<_::bits-size(^index), x::1, _::bits>> = bitfield
    x === 1
  end

  @spec count(binary(), pos_integer()) :: non_neg_integer()
  def count(bitfield, pieces_count) when is_binary(bitfield) and is_integer(pieces_count) do
    Enum.count(0..(pieces_count - 1), &have?(bitfield, &1))
  end

  defp size(pieces_count) do
    (pieces_count / 8)
    |> Float.ceil()
    |> trunc()
  end
end

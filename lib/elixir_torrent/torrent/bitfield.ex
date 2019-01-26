defmodule Torrent.Bitfield do
  @spec make(pos_integer()) :: binary()
  def make(count) do
    count
    |> size()
    |> (&List.duplicate(0, &1)).()
    |> :binary.list_to_bin()
  end

  @spec set(binary(), non_neg_integer(), 0 | 1) :: binary()
  def set(bitfield, index, x) do
    <<prefix::bits-size(index), _::1, postfix::bits>> = bitfield
    <<prefix::bits, x::1, postfix::bits>>
  end

  @spec have?(binary(), non_neg_integer()) :: boolean()
  def have?(bitfield, index) do
    <<_::bits-size(index), x::1, _::bits>> = bitfield
    x === 1
  end

  defp size(pieces_count) do
    (pieces_count / 8)
    |> Float.ceil()
    |> trunc()
  end
end

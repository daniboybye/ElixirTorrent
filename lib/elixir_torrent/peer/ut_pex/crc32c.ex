defmodule Peer.UtPex.CRC32C do
  @moduledoc false

  # CRC32C (Castagnoli, polynomial 0x82F63B78) — BEP 40 and BEP 42, not IEEE CRC32.

  @poly 0x82F63B78

  @spec checksum(binary()) :: non_neg_integer()
  def checksum(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reduce(0xFFFFFFFF, fn byte, crc ->
      crc = Bitwise.bxor(crc, byte)

      Enum.reduce(0..7, crc, fn _, c -> crc_shift_step(c) end)
    end)
    |> Bitwise.bxor(0xFFFFFFFF)
    |> Bitwise.band(0xFFFFFFFF)
  end

  defp crc_shift_step(c) do
    if Bitwise.band(c, 1) == 1 do
      Bitwise.bxor(Bitwise.bsr(c, 1), @poly)
    else
      Bitwise.bsr(c, 1)
    end
  end
end

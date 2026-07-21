defmodule DHT.BEP42 do
  @moduledoc false
  # BEP 42 — bind node IDs to external IP via CRC32C so one host can't flood
  # multiple routing-table slots (Sybil resistance). Peers on the same /24 (v4)
  # or /48 (v6) share an ID prefix; random middle bytes keep IDs unique.

  @v4_mask {0x03, 0x0F, 0x3F, 0xFF}
  @v6_mask {0x01, 0x03, 0x07, 0x0F, 0x1F, 0x3F, 0x7F, 0xFF}

  @type ip :: :inet.ip_address()

  @doc """
  Generate a 20-byte BEP-42 node id for `ip`.

  `rand_byte` is persisted per installation (byte 19 of the id); `r = rand_byte & 7`
  is embedded in the masked IP before CRC32C. Middle bytes (3..18) are random and
  also persisted so restarts keep a stable identity when the IP is unchanged.
  """
  @spec generate(ip(), byte(), binary()) :: <<_::160>>
  def generate(ip, rand_byte, middle \\ :crypto.strong_rand_bytes(16))
      when is_binary(middle) and byte_size(middle) == 16 do
    r = Bitwise.band(rand_byte, 0x07)
    crc = ip |> mask_ip(r) |> crc32c()
    low3 = Bitwise.band(:crypto.strong_rand_bytes(1) |> :binary.at(0), 0x07)
    b2 = Bitwise.bor(Bitwise.band(Bitwise.bsr(crc, 8), 0xF8), low3)

    <<byte0(crc)::8, byte1(crc)::8, b2::8, middle::binary-size(16), rand_byte::8>>
  end

  @doc "True when the first 21 bits + last byte of `node_id` match `ip` per BEP 42."
  @spec valid?(<<_::160>>, ip()) :: boolean()
  def valid?(<<id::binary-size(20)>>, ip) do
    r = Bitwise.band(:binary.at(id, 19), 0x07)
    crc = ip |> mask_ip(r) |> crc32c()

    byte0(crc) == :binary.at(id, 0) and byte1(crc) == :binary.at(id, 1) and
      Bitwise.band(Bitwise.bsr(crc, 8), 0xF8) == Bitwise.band(:binary.at(id, 2), 0xF8) and
      Bitwise.band(:binary.at(id, 19), 0x07) == r
  end

  defp byte0(crc), do: Bitwise.band(Bitwise.bsr(crc, 24), 0xFF)
  defp byte1(crc), do: Bitwise.band(Bitwise.bsr(crc, 16), 0xFF)

  defp mask_ip({a, b, c, d}, r) do
    {m0, m1, m2, m3} = @v4_mask
    <<Bitwise.bor(Bitwise.band(a, m0), Bitwise.bsl(r, 5)), Bitwise.band(b, m1), Bitwise.band(c, m2),
      Bitwise.band(d, m3)>>
  end

  defp mask_ip({a, b, c, d, e, f, g, h}, r) do
    {m0, m1, m2, m3, m4, m5, m6, m7} = @v6_mask
    <<Bitwise.bor(Bitwise.band(a, m0), Bitwise.bsl(r, 5)), Bitwise.band(b, m1), Bitwise.band(c, m2),
      Bitwise.band(d, m3), Bitwise.band(e, m4), Bitwise.band(f, m5), Bitwise.band(g, m6),
      Bitwise.band(h, m7)>>
  end

  # CRC32C (Castagnoli) — BEP 42 mandates this polynomial, not IEEE CRC32.
  @crc32c_poly 0x82F63B78

  defp crc32c(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reduce(0xFFFFFFFF, fn byte, crc ->
      crc = Bitwise.bxor(crc, byte)

      Enum.reduce(0..7, crc, fn _, c ->
        if Bitwise.band(c, 1) == 1 do
          Bitwise.bxor(Bitwise.bsr(c, 1), @crc32c_poly)
        else
          Bitwise.bsr(c, 1)
        end
      end)
    end)
    |> Bitwise.bxor(0xFFFFFFFF)
    |> Bitwise.band(0xFFFFFFFF)
  end
end

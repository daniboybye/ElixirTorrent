defmodule DHT.BEP42Test do
  use ExUnit.Case, async: true

  alias DHT.BEP42

  # Vector from BEP 42 / StackOverflow: 21.75.31.124, rand=86 → r=2, crc prefix 0x5a3ce9
  @sample_v4 {21, 75, 31, 124}
  @sample_rand 86

  test "generate/3 sets the BEP-42 prefix bytes for a known IPv4 + rand" do
    id = BEP42.generate(@sample_v4, @sample_rand, :crypto.strong_rand_bytes(16))

    assert <<0x5A, 0x3C, b2, _::binary>> = id
    assert Bitwise.band(b2, 0xF8) == 0xE8
    assert :binary.at(id, 19) == @sample_rand
    assert BEP42.valid?(id, @sample_v4)
  end

  test "valid?/2 rejects an id generated for a different IP" do
    id = BEP42.generate(@sample_v4, @sample_rand, :crypto.strong_rand_bytes(16))
    refute BEP42.valid?(id, {1, 2, 3, 4})
  end

  test "generate/3 works for IPv6" do
    ip = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    id = BEP42.generate(ip, 42, :crypto.strong_rand_bytes(16))
    assert BEP42.valid?(id, ip)
  end

  test "IPv6 masks the high 64 network-order bits, not the low bytes of tuple segments" do
    ip = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    id = BEP42.generate(ip, 2, <<0::128>>)

    assert <<0x66, 0x89, b2, _::binary>> = id
    assert Bitwise.band(b2, 0xF8) == 0x00
  end

  test "local IPv4 and IPv6 ranges are exempt from inbound validation" do
    arbitrary_id = :binary.copy(<<0xFF>>, 20)

    for ip <- [
          {10, 0, 0, 1},
          {172, 16, 0, 1},
          {192, 168, 0, 1},
          {169, 254, 0, 1},
          {127, 0, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFD00, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1}
        ] do
      assert BEP42.valid_or_exempt?(arbitrary_id, ip)
    end
  end
end

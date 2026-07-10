defmodule Peer.UtPexTest do
  use ExUnit.Case, async: true

  alias Peer.UtPex

  test "encode/decode IPv4 peer delta" do
    added = [{{1, 2, 3, 4}, 6881}, {{5, 6, 7, 8}, 51413}]
    dropped = [{{9, 9, 9, 9}, 6000}]

    payload = UtPex.encode(added, dropped)
    assert is_binary(payload)
    assert {:ok, ^added, ^dropped} = UtPex.decode(payload)
  end

  test "decode ignores unknown keys" do
    raw =
      Bento.encode!(%{
        "added" => <<1, 2, 3, 4, 0x1A, 0xE1>>,
        "added.f" => <<0>>,
        "foo" => "bar"
      })

    assert {:ok, [{{1, 2, 3, 4}, 6881}], []} = UtPex.decode(raw)
  end
end

defmodule BittorrentTest do
  use ExUnit.Case, async: true

  test "allowed fast set" do
    hash = List.duplicate(0xAA, 20) |> :binary.list_to_bin()
    list = [1059, 431, 808, 1217, 287, 376, 1188]
    ip = {80, 4, 4, 200}
    pieces = 1313
    assert AllowedFast.set(ip, hash, pieces, 7) == MapSet.new(list)
    assert AllowedFast.set(ip, hash, pieces, 9) == MapSet.new([353, 508 | list])
  end

  test "allowed fast set is capped by small torrent piece count" do
    hash = :binary.copy(<<0xAA>>, 20)

    assert AllowedFast.set({80, 4, 4, 200}, hash, 3) == MapSet.new(0..2)

    assert AllowedFast.set({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, hash, 2) ==
             MapSet.new(0..1)
  end

  test "allowed fast set is empty when no piece can be selected" do
    hash = :binary.copy(<<0xAA>>, 20)
    assert AllowedFast.set({80, 4, 4, 200}, hash, 0) == MapSet.new()
    assert AllowedFast.set({80, 4, 4, 200}, hash, 10, 0) == MapSet.new()
  end
end

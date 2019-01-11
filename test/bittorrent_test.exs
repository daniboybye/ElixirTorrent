defmodule BittorrentTest do
  use ExUnit.Case

  test "allowed fast set" do
    hash = List.duplicate(0xAA, 20) |> :binary.list_to_bin()
    list = [1059, 431, 808, 1217, 287, 376, 1188]
    ip = {80, 4, 4, 200}
    pieces = 1313
    assert AllowedFast.set(ip, hash, pieces, 7) == MapSet.new(list)
    assert AllowedFast.set(ip, hash, pieces, 9) == MapSet.new([353, 508 | list])
  end
end

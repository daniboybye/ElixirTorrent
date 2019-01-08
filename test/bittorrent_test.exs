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

  alias Torrent.PiecesStatistic

  test "pieces statistic" do
    assert PiecesStatistic.handle_call(:rare, nil, %{1 => 2}) == {:reply, 1, %{}}
    assert PiecesStatistic.handle_call(:rare, nil, %{1 => 0}) == {:reply, nil, %{1 => 0}}

    assert PiecesStatistic.handle_call(:rare, nil, %{1 => 1, 2 => :priority}) ==
             {:reply, 2, %{1 => 1}}

    assert PiecesStatistic.handle_call(:rare, nil, %{
             1 => 1,
             2 => :priority,
             3 => {:allowed_fast, 9}
           }) == {:reply, 3, %{1 => 1, 2 => :priority}}

    assert PiecesStatistic.handle_call(:rare, nil, %{2 => :priority, 3 => {:allowed_fast, 9}}) ==
             {:reply, 3, %{2 => :priority}}

    assert PiecesStatistic.handle_call(:rare, nil, %{3 => :priority}) == {:reply, 3, %{}}
  end
end

defmodule BittorrentTest do
  use ExUnit.Case
  doctest Bittorrent

  test "greets the world" do
    assert Bittorrent.hello() == :world
  end
end

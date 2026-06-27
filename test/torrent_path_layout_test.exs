defmodule Torrent.PathLayoutTest do
  use ExUnit.Case, async: true

  alias Torrent.PathLayout

  @multi_info %{
    "name" => "My Album",
    "files" => [
      %{"length" => 100, "path" => ["track1.mp3"]},
      %{"length" => 200, "path" => ["track2.mp3"]}
    ]
  }

  @foldered_info %{
    "name" => "ignored",
    "files" => [
      %{"length" => 100, "path" => ["dir", "a.bin"]},
      %{"length" => 200, "path" => ["dir", "b.bin"]}
    ]
  }

  test "single-file torrent writes directly into download root" do
    info = %{"length" => 1_024, "name" => "ubuntu.iso"}
    cwd = "/downloads"

    assert PathLayout.disk_paths(info, cwd) == ["/downloads/ubuntu.iso"]
    assert PathLayout.relative_path(info, ["ubuntu.iso"]) == "ubuntu.iso"
  end

  test "multi-file torrent with shared top-level folder keeps paths as-is" do
    cwd = "/downloads"

    assert PathLayout.disk_paths(@foldered_info, cwd) == [
             "/downloads/dir/a.bin",
             "/downloads/dir/b.bin"
           ]

    assert PathLayout.relative_path(@foldered_info, ["dir", "a.bin"]) == "dir/a.bin"
  end

  test "multi-file torrent with loose top-level files wraps in info.name" do
    cwd = "/downloads"

    assert PathLayout.disk_paths(@multi_info, cwd) == [
             "/downloads/My Album/track1.mp3",
             "/downloads/My Album/track2.mp3"
           ]

    assert PathLayout.relative_path(@multi_info, ["track1.mp3"]) == "My Album/track1.mp3"
  end

  test "sanitize_name replaces path separators" do
    assert PathLayout.sanitize_name("foo/bar\\baz") == "foo_bar_baz"
    assert PathLayout.sanitize_name("") == "download"
  end
end

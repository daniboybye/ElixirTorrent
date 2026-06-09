defmodule Torrent.FilesTest do
  use ExUnit.Case, async: true

  alias Torrent.Bitfield
  alias Torrent.Files

  test "single-file torrent progress from bitfield" do
    torrent = %Torrent{
      hash: <<0::160>>,
      metadata: %{
        "info" => %{
          "name" => "ubuntu.iso",
          "length" => 32_768,
          "piece length" => 16_384,
          "pieces" => :crypto.hash(:sha, "a") <> :crypto.hash(:sha, "b")
        }
      },
      left: 16_384,
      last_index: 1,
      last_piece_length: 16_384,
      bitfield: Bitfield.make(2) |> Bitfield.set(0, 1)
    }

    [file] = Files.build_entries(torrent)

    assert file.name == "ubuntu.iso"
    assert file.length == 32_768
    assert file.downloaded == 16_384
    assert file.progress == 50.0
    refute file.complete?
  end

  test "multi-file torrent maps each file independently" do
    torrent = %Torrent{
      hash: <<1::160>>,
      metadata: %{
        "info" => %{
          "name" => "folder",
          "piece length" => 16,
          "pieces" => :crypto.hash(:sha, "a"),
          "files" => [
            %{"length" => 8, "path" => ["readme.txt"]},
            %{"length" => 8, "path" => ["video", "clip.mp4"]}
          ]
        }
      },
      left: 0,
      last_index: 0,
      last_piece_length: 16,
      bitfield: Bitfield.make(1) |> Bitfield.set(0, 1)
    }

    [readme, clip] = Files.build_entries(torrent)

    assert readme.path == "readme.txt"
    assert readme.complete?
    assert clip.path == Path.join(["video", "clip.mp4"])
    assert clip.complete?
  end
end

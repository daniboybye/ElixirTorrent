defmodule Torrent.FilesTest do
  use ExUnit.Case, async: true

  alias Torrent.{Bitfield, Files}

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

    assert readme.path == Path.join(["folder", "readme.txt"])
    assert readme.complete?
    assert clip.path == Path.join(["folder", "video", "clip.mp4"])
    assert clip.complete?
  end

  test "BEP 47 padding files are hidden but still shift real-file offsets" do
    # Layout in the piece stream:
    #   [0..7]   readme.txt   (real, 8 bytes)
    #   [8..15]  .pad/8       (padding, 8 bytes → gets us to piece boundary 16)
    #   [16..23] clip.mp4     (real, 8 bytes)
    #
    # Bitfield: piece 0 = NOT complete, piece 1 = complete. clip.mp4 spans
    # piece 1 only, so it must show `complete? == true`.
    #
    # Regression guard: a naive "just drop pad entries" reducer that doesn't
    # advance the running offset would place clip.mp4 at offset 8 (piece 0
    # territory) instead of 16 — and this test would then flip to
    # `complete? == false` because piece 0 isn't in the bitfield.
    torrent = %Torrent{
      hash: <<2::160>>,
      metadata: %{
        "info" => %{
          "name" => "folder",
          "piece length" => 16,
          "pieces" => :crypto.hash(:sha, "a") <> :crypto.hash(:sha, "b"),
          "files" => [
            %{"length" => 8, "path" => ["readme.txt"]},
            %{"length" => 8, "path" => [".pad", "8"], "attr" => "p"},
            %{"length" => 8, "path" => ["video", "clip.mp4"]}
          ]
        }
      },
      left: 16,
      last_index: 1,
      last_piece_length: 16,
      bitfield: Bitfield.make(2) |> Bitfield.set(1, 1)
    }

    entries = Files.build_entries(torrent)
    assert length(entries) == 2

    [readme, clip] = entries
    assert readme.name == "readme.txt"
    refute readme.complete?

    assert clip.name == "clip.mp4"
    assert clip.length == 8
    assert clip.complete?, "clip.mp4 must be reported at offset 16 (piece 1), not 8 (piece 0)"
  end

  test "Files.padding?/1 recognises BEP 47 attr flag" do
    assert Files.padding?(%{"attr" => "p"})
    assert Files.padding?(%{"attr" => "ph"})
    refute Files.padding?(%{"attr" => "h"})
    refute Files.padding?(%{"path" => [".pad", "8"]})
    refute Files.padding?(%{})
  end
end

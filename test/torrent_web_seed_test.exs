defmodule Torrent.WebSeedTest do
  use ExUnit.Case, async: true

  alias Torrent.WebSeed

  describe "span_files/3" do
    test "single-file torrent, piece fully inside file" do
      info = %{"length" => 10_000, "name" => "big.iso"}

      assert WebSeed.span_files(info, 0, 999) ==
               [%{path: ["big.iso"], offset: 0, length: 1_000}]

      assert WebSeed.span_files(info, 5_000, 6_499) ==
               [%{path: ["big.iso"], offset: 5_000, length: 1_500}]
    end

    test "single-file torrent, piece truncated at file end" do
      info = %{"length" => 1_000, "name" => "small.bin"}

      assert WebSeed.span_files(info, 800, 1_999) ==
               [%{path: ["small.bin"], offset: 800, length: 200}]
    end

    test "multi-file torrent, piece contained in one file" do
      info = %{
        "name" => "album",
        "files" => [
          %{"length" => 1_000, "path" => ["a.mp3"]},
          %{"length" => 1_000, "path" => ["b.mp3"]},
          %{"length" => 1_000, "path" => ["c.mp3"]}
        ]
      }

      assert WebSeed.span_files(info, 500, 999) ==
               [%{path: ["a.mp3"], offset: 500, length: 500}]

      assert WebSeed.span_files(info, 1_500, 1_999) ==
               [%{path: ["b.mp3"], offset: 500, length: 500}]
    end

    test "multi-file torrent, piece spans two files" do
      info = %{
        "name" => "album",
        "files" => [
          %{"length" => 1_000, "path" => ["a.mp3"]},
          %{"length" => 1_000, "path" => ["b.mp3"]}
        ]
      }

      assert WebSeed.span_files(info, 800, 1_199) == [
               %{path: ["a.mp3"], offset: 800, length: 200},
               %{path: ["b.mp3"], offset: 0, length: 200}
             ]
    end

    test "multi-file torrent, piece spans three files" do
      info = %{
        "name" => "album",
        "files" => [
          %{"length" => 100, "path" => ["a"]},
          %{"length" => 50, "path" => ["b"]},
          %{"length" => 200, "path" => ["c"]}
        ]
      }

      # bytes 90..179 → last 10 of a, all 50 of b, first 30 of c
      assert WebSeed.span_files(info, 90, 179) == [
               %{path: ["a"], offset: 90, length: 10},
               %{path: ["b"], offset: 0, length: 50},
               %{path: ["c"], offset: 0, length: 30}
             ]
    end
  end

  describe "parse_url_list/1" do
    test "single string is wrapped into a list" do
      assert WebSeed.parse_url_list(%{"url-list" => "http://mirror.example/file.iso"}) ==
               ["http://mirror.example/file.iso"]
    end

    test "list of strings is preserved and de-duplicated" do
      assert WebSeed.parse_url_list(%{
               "url-list" => [
                 "http://a.example/",
                 "http://a.example/",
                 "https://b.example/x"
               ]
             }) == ["http://a.example/", "https://b.example/x"]
    end

    test "non-HTTP entries are dropped" do
      assert WebSeed.parse_url_list(%{
               "url-list" => ["udp://tracker/x", "http://ok/", "ftp://old/"]
             }) == ["http://ok/"]
    end

    test "missing url-list yields empty" do
      assert WebSeed.parse_url_list(%{}) == []
      assert WebSeed.parse_url_list(%{"url-list" => ""}) == []
      assert WebSeed.parse_url_list(%{"url-list" => nil}) == []
    end

    test "non-map input yields empty" do
      assert WebSeed.parse_url_list(nil) == []
      assert WebSeed.parse_url_list("not a map") == []
    end
  end
end

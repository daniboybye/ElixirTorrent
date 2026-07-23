defmodule TorrentV2DetectionTest do
  use ExUnit.Case, async: true

  # BEP 52: `info["meta version"] = 2` marks a torrent as BitTorrent v2. A
  # torrent that also keeps the v1 `info["pieces"]` list is a **hybrid** —
  # both info-hashes address the same content, aligned via BEP 47 padding
  # files. A v2-only torrent (no `pieces` field) requires the full merkle
  # verification stack which isn't shipped yet, so parse_file! rejects it
  # cleanly instead of half-loading it.

  defp bstr(binary), do: [Integer.to_string(byte_size(binary)), ":", binary]
  defp bint(n), do: ["i", Integer.to_string(n), "e"]

  defp write_tmp!(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_v2_#{System.unique_integer([:positive])}.torrent"
      )

    File.write!(path, bytes)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  # A minimal v1 info dict — 20-byte SHA-1 piece list, single-file `length`.
  defp v1_info_blob(name \\ "hello") do
    pieces = :binary.copy(<<0>>, 20)

    IO.iodata_to_binary([
      "d",
      bstr("length"),
      bint(42),
      bstr("name"),
      bstr(name),
      bstr("piece length"),
      bint(16_384),
      bstr("pieces"),
      bstr(pieces),
      "e"
    ])
  end

  # A hybrid info dict — v1 fields + `meta version = 2` + a minimal
  # `file tree` entry. We do not fill the merkle tree fields; detection
  # only depends on the two markers.
  defp hybrid_info_blob(name \\ "hello") do
    pieces = :binary.copy(<<0>>, 20)
    file_tree_leaf = IO.iodata_to_binary(["d", bstr(""), "d", bstr("length"), bint(42), "e", "e"])
    file_tree = IO.iodata_to_binary(["d", bstr(name), file_tree_leaf, "e"])

    IO.iodata_to_binary([
      "d",
      bstr("file tree"),
      file_tree,
      bstr("length"),
      bint(42),
      bstr("meta version"),
      bint(2),
      bstr("name"),
      bstr(name),
      bstr("piece length"),
      bint(16_384),
      bstr("pieces"),
      bstr(pieces),
      "e"
    ])
  end

  # A pure-v2 info dict — `meta version = 2` and `file tree`, no `pieces`
  # and no `files`/`length`.
  defp v2_only_info_blob(name \\ "hello") do
    file_tree_leaf =
      IO.iodata_to_binary([
        "d",
        bstr(""),
        "d",
        bstr("length"),
        bint(42),
        bstr("pieces root"),
        bstr(:binary.copy(<<0>>, 32)),
        "e",
        "e"
      ])

    file_tree = IO.iodata_to_binary(["d", bstr(name), file_tree_leaf, "e"])

    IO.iodata_to_binary([
      "d",
      bstr("file tree"),
      file_tree,
      bstr("meta version"),
      bint(2),
      bstr("name"),
      bstr(name),
      bstr("piece length"),
      bint(16_384),
      "e"
    ])
  end

  defp wrap_torrent(info_blob) do
    IO.iodata_to_binary([
      "d",
      bstr("announce"),
      bstr("http://tracker.example.com/announce"),
      bstr("info"),
      info_blob,
      "e"
    ])
  end

  describe "detect_kind/1" do
    test "plain v1 torrent" do
      metadata = Bento.decode!(wrap_torrent(v1_info_blob()))
      assert Torrent.detect_kind(metadata) == :v1
    end

    test "hybrid torrent — v1 pieces + v2 meta version" do
      metadata = Bento.decode!(wrap_torrent(hybrid_info_blob()))
      assert Torrent.detect_kind(metadata) == :hybrid
    end

    test "pure v2 torrent — meta version 2, no v1 pieces" do
      metadata = Bento.decode!(wrap_torrent(v2_only_info_blob()))
      assert Torrent.detect_kind(metadata) == :v2
    end

    test "malformed / missing info dict is treated as v1" do
      assert Torrent.detect_kind(%{}) == :v1
      assert Torrent.detect_kind(:garbage) == :v1
    end
  end

  describe "parse_file!/1" do
    test "v1 → kind :v1, hash_v2 nil, hash is SHA-1(info_blob)" do
      info_blob = v1_info_blob()
      path = write_tmp!(wrap_torrent(info_blob))
      torrent = Torrent.parse_file!(path)

      assert torrent.kind == :v1
      assert torrent.hash == :crypto.hash(:sha, info_blob)
      assert is_nil(torrent.hash_v2)
      assert torrent.info_blob == info_blob
    end

    test "hybrid → kind :hybrid, hash_v2 = SHA-256(info_blob), v1 hash still set" do
      info_blob = hybrid_info_blob()
      path = write_tmp!(wrap_torrent(info_blob))
      torrent = Torrent.parse_file!(path)

      assert torrent.kind == :hybrid
      assert torrent.hash == :crypto.hash(:sha, info_blob)
      assert torrent.hash_v2 == :crypto.hash(:sha256, info_blob)
      assert byte_size(torrent.hash_v2) == 32
      # v1 fields still populated so the v1 downloader keeps working end-to-end.
      assert torrent.metadata["info"]["pieces"]
      assert torrent.last_piece_length == 42
    end

    test "pure v2 → raises with a clear \"not yet supported\" message" do
      path = write_tmp!(wrap_torrent(v2_only_info_blob()))

      assert_raise ArgumentError, ~r/BitTorrent v2 \(BEP 52\).+not yet supported/, fn ->
        Torrent.parse_file!(path)
      end
    end
  end
end

defmodule TorrentInfoHashTest do
  use ExUnit.Case, async: true

  # BEP 3: info_hash is SHA-1 of the raw bencoded info dict as it appears on the
  # wire. Any .torrent whose info dict is not byte-identical after re-encoding
  # (e.g. non-canonical key order preserved by the client's decoder) would get
  # the wrong info_hash under the old re-encode strategy → silently never
  # finds peers. Regression: prove parse_file! slices the raw bytes.

  defp write_tmp!(bytes) do
    path = Path.join(System.tmp_dir!(), "elixir_torrent_test_#{System.unique_integer([:positive])}.torrent")
    File.write!(path, bytes)
    on_exit_delete(path)
    path
  end

  defp on_exit_delete(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
  end

  defp bstr(binary), do: [Integer.to_string(byte_size(binary)), ":", binary]

  defp bint(n), do: ["i", Integer.to_string(n), "e"]

  # Info dict with keys in NON-canonical order ("name" before "length") so
  # Bento's re-encode reorders them. The old code (Bento.encode! then SHA-1)
  # therefore produces a different hash than the raw slice — a real-world
  # trigger for the "silently never finds peers" bug.
  defp non_canonical_info_blob do
    pieces = :binary.copy(<<0>>, 20)

    IO.iodata_to_binary([
      "d",
      bstr("name"), bstr("hello"),
      bstr("length"), bint(42),
      bstr("piece length"), bint(16_384),
      bstr("pieces"), bstr(pieces),
      "e"
    ])
  end

  test "parse_file! slices raw info bytes and derives correct info_hash" do
    info_blob = non_canonical_info_blob()
    expected_hash = :crypto.hash(:sha, info_blob)

    file_bytes =
      IO.iodata_to_binary([
        "d",
        bstr("announce"), bstr("http://tracker.example.com/announce"),
        bstr("info"), info_blob,
        "e"
      ])

    path = write_tmp!(file_bytes)
    torrent = Torrent.parse_file!(path)

    assert torrent.hash == expected_hash
    assert torrent.info_blob == info_blob

    # Sanity: the old (re-encode) path would have produced a different hash for
    # this file. Guard the regression by proving Bento re-encode differs.
    reencoded = Bento.encode!(torrent.metadata["info"])
    refute reencoded == info_blob
    refute :crypto.hash(:sha, reencoded) == expected_hash
  end

  test "Torrent.Metadata.info_blob returns the sliced bytes without re-encoding" do
    info_blob = non_canonical_info_blob()

    file_bytes =
      IO.iodata_to_binary([
        "d",
        bstr("info"), info_blob,
        "e"
      ])

    path = write_tmp!(file_bytes)
    torrent = Torrent.parse_file!(path)

    # Direct struct-level check (Metadata reads via Torrent.get which needs the
    # Model GenServer; the sliced bytes live on the struct itself).
    assert torrent.info_blob == info_blob
    assert :crypto.hash(:sha, torrent.info_blob) == torrent.hash
  end
end

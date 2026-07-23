defmodule MagnetV2Test do
  use ExUnit.Case, async: true

  # BEP 52 § "Extension to the magnet URI format": v2 magnets carry the
  # infohash as `xt=urn:btmh:<multihash>`. sha2-256 multihash =
  # `<<0x12, 0x20>>` prefix + 32-byte digest. Hybrid magnets carry both
  # `xt=urn:btih:<sha1>` and `xt=urn:btmh:<multihash>` addressing the same
  # torrent — we accept those and expose both hashes.

  defp v1_hex do
    hash = :crypto.hash(:sha, "v1")
    Base.encode16(hash, case: :lower)
  end

  defp v2_hex do
    hash = :crypto.hash(:sha256, "v2")
    Base.encode16(<<0x12, 0x20, hash::binary>>, case: :lower)
  end

  defp v2_base32 do
    hash = :crypto.hash(:sha256, "v2b32")
    Base.encode32(<<0x12, 0x20, hash::binary>>, padding: false)
  end

  test "btih-only magnet — kind :v1, hash_v2 nil" do
    uri = "magnet:?xt=urn:btih:#{v1_hex()}&dn=v1only"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.kind == :v1
    assert byte_size(magnet.hash) == 20
    assert is_nil(magnet.hash_v2)
    assert magnet.display_name == "v1only"
  end

  test "hybrid magnet — btih + btmh in separate xt.N params" do
    uri =
      "magnet:?xt.1=urn:btih:#{v1_hex()}&xt.2=urn:btmh:#{v2_hex()}&dn=hybrid"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.kind == :hybrid
    assert byte_size(magnet.hash) == 20
    assert byte_size(magnet.hash_v2) == 32
    assert magnet.display_name == "hybrid"
  end

  test "hybrid magnet — duplicate xt= keys survive the query walk" do
    # URI.decode_query/1 collapses duplicate keys, but our extractor walks
    # the raw query so this style (used by libtorrent-generated magnets)
    # still yields both hashes.
    uri = "magnet:?xt=urn:btih:#{v1_hex()}&xt=urn:btmh:#{v2_hex()}"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.kind == :hybrid
    assert byte_size(magnet.hash) == 20
    assert byte_size(magnet.hash_v2) == 32
  end

  test "pure-v2 magnet (btmh only) is rejected as v2_only_unsupported" do
    uri = "magnet:?xt=urn:btmh:#{v2_hex()}"
    assert {:error, :v2_only_unsupported} = Magnet.parse(uri)
  end

  test "base32-encoded btmh is accepted (hybrid form)" do
    uri = "magnet:?xt.1=urn:btih:#{v1_hex()}&xt.2=urn:btmh:#{v2_base32()}"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.kind == :hybrid
    assert byte_size(magnet.hash_v2) == 32
  end

  test "malformed btmh — wrong length — is rejected" do
    # 66 hex chars instead of the required 68 (missing 2 chars → not the
    # multihash 0x1220 sha2-256 shape).
    short = String.duplicate("a", 66)
    uri = "magnet:?xt=urn:btmh:#{short}"
    assert {:error, :invalid_btmh} = Magnet.parse(uri)
  end

  test "malformed btmh — wrong multihash prefix — is rejected" do
    # 68 hex chars but the leading two bytes are `0x00 0x20` instead of
    # `0x12 0x20` (0x12 = sha2-256 code point). This is the tell for a
    # client that used a non-sha256 hash or a non-multihash raw digest.
    bad =
      Base.encode16(<<0x00, 0x20, :crypto.hash(:sha256, "x")::binary>>, case: :lower)

    uri = "magnet:?xt=urn:btmh:#{bad}"
    assert {:error, :invalid_btmh} = Magnet.parse(uri)
  end

  test "unrelated xt values (e.g. urn:sha1:) are ignored alongside a valid btih" do
    other = Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    uri =
      "magnet:?xt=urn:sha1:#{other}&xt=urn:btih:#{v1_hex()}"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.kind == :v1
    assert byte_size(magnet.hash) == 20
  end

  test "merge_trackers preserves the hybrid upgrade" do
    v1_only = %Magnet{
      hash: :crypto.hash(:sha, "v1"),
      hash_v2: nil,
      kind: :v1,
      trackers: ["udp://a/announce"],
      display_name: "A",
      x_pe_peers: []
    }

    hybrid = %Magnet{
      hash: :crypto.hash(:sha, "v1"),
      hash_v2: :crypto.hash(:sha256, "v2"),
      kind: :hybrid,
      trackers: ["udp://b/announce"],
      display_name: nil,
      x_pe_peers: []
    }

    merged = Magnet.merge_trackers(v1_only, hybrid)
    assert merged.kind == :hybrid
    assert byte_size(merged.hash_v2) == 32
    assert length(merged.trackers) == 2
  end
end

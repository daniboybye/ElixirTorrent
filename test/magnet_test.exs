defmodule MagnetTest do
  use ExUnit.Case, async: true

  test "parses hex btih and trackers" do
    hash =
      :crypto.hash(
        :sha,
        Bento.encode!(%{"name" => "test", "piece length" => 16384, "pieces" => <<0::160>>})
      )

    hex = Base.encode16(hash, case: :lower)

    uri =
      "magnet:?xt=urn:btih:#{hex}&dn=Example&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=http%3A%2F%2Ftracker.example.com%2Fannounce"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.hash == hash
    assert magnet.display_name == "Example"
    assert length(magnet.trackers) == 2
    assert "udp://tracker.opentrackr.org:1337/announce" in magnet.trackers
  end

  test "normalizes tracker URLs missing /announce path" do
    hash = :crypto.strong_rand_bytes(20)
    hex = Base.encode16(hash, case: :lower)

    uri =
      "magnet:?xt=urn:btih:#{hex}&tr=udp%3A%2F%2Ftracker.coppersurfer.tk%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=http%3A%2F%2F173.212.234.232%3A2710%2Fannounce"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert "udp://tracker.coppersurfer.tk:6969/announce" in magnet.trackers
    assert "udp://tracker.opentrackr.org:1337/announce" in magnet.trackers
    assert "http://173.212.234.232:2710/announce" in magnet.trackers
  end

  test "decodes display name with brackets and parentheses" do
    hash = :crypto.strong_rand_bytes(20)
    hex = Base.encode16(hash, case: :lower)

    uri =
      "magnet:?xt=urn:btih:#{hex}&dn=%5BBigTitsAtSchool%5D+Diamond+Jackson+%2828.06.2018%29+rq.mp4"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.display_name == "[BigTitsAtSchool] Diamond Jackson (28.06.2018) rq.mp4"
  end

  test "merge_trackers unions tracker URLs without dropping existing" do
    hash = <<1::160>>

    base = %Magnet{
      hash: hash,
      trackers: ["udp://tracker.opentrackr.org:1337/announce"],
      display_name: "A",
      x_pe_peers: []
    }

    incoming = %Magnet{
      hash: hash,
      trackers: ["udp://tracker.coppersurfer.tk:6969/announce", "udp://tracker.opentrackr.org:1337/announce"],
      display_name: nil,
      x_pe_peers: []
    }

    merged = Magnet.merge_trackers(base, incoming)
    assert length(merged.trackers) == 2
    assert merged.display_name == "A"
  end

  test "rejects non-magnet scheme" do
    assert {:error, :invalid_scheme} = Magnet.parse("http://example.com")
  end

  test "rejects magnet without xt" do
    assert {:error, :missing_xt} = Magnet.parse("magnet:?tr=http://tracker.example.com/announce")
  end

  test "parses x.pe embedded peers" do
    hash =
      :crypto.hash(
        :sha,
        Bento.encode!(%{"name" => "test", "piece length" => 16384, "pieces" => <<0::160>>})
      )

    hex = Base.encode16(hash, case: :lower)

    uri =
      "magnet:?xt=urn:btih:#{hex}&x.pe=127.0.0.1%3A6881&x.pe.1=192.168.1.2%3A6882"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert length(magnet.x_pe_peers) == 2
    assert %Peer{ip: {127, 0, 0, 1}, port: 6881} in magnet.x_pe_peers
    assert %Peer{ip: {192, 168, 1, 2}, port: 6882} in magnet.x_pe_peers
  end

  test "ignores invalid x.pe values" do
    hash = :crypto.strong_rand_bytes(20)
    hex = Base.encode16(hash, case: :lower)
    uri = "magnet:?xt=urn:btih:#{hex}&x.pe=not-an-ip:abc"

    assert {:ok, magnet} = Magnet.parse(uri)
    assert magnet.x_pe_peers == []
  end

  test "private? detects BEP 27 private flag" do
    assert Magnet.private?(%{"private" => 1})
    refute Magnet.private?(%{"private" => 0})
    refute Magnet.private?(%{"name" => "example"})
  end
end

defmodule Magnet.UtMetadataTest do
  use ExUnit.Case, async: true

  @block Magnet.UtMetadata.block_size()

  test "piece_count and last-piece byte size follow BEP 9 16 KiB blocks" do
    assert Magnet.UtMetadata.piece_count(1) == 1
    assert Magnet.UtMetadata.piece_byte_size(1, 0) == 1

    assert Magnet.UtMetadata.piece_count(@block) == 1
    assert Magnet.UtMetadata.piece_byte_size(@block, 0) == @block

    assert Magnet.UtMetadata.piece_count(@block + 1) == 2
    assert Magnet.UtMetadata.piece_byte_size(@block + 1, 0) == @block
    assert Magnet.UtMetadata.piece_byte_size(@block + 1, 1) == 1

    assert Magnet.UtMetadata.piece_count(34_256) == 3
    assert Magnet.UtMetadata.piece_byte_size(34_256, 2) == 34_256 - 2 * @block
  end

  test "encode_data and encode_reject follow BEP 9 wire layout" do
    data = <<1, 2, 3>>
    payload = Magnet.UtMetadata.encode_data(0, 3, data)

    assert {:ok, {:data, [piece: 0, total_size: 3, data: ^data]}} =
             Magnet.UtMetadata.decode_message(payload)

    assert Magnet.UtMetadata.encode_reject(2) == "d8:msg_typei2e5:piecei2ee"
  end

  test "decode_message parses request, data, and reject payloads" do
    assert {:ok, {:request, [piece: 0]}} =
             Magnet.UtMetadata.decode_message("d8:msg_typei0e5:piecei0ee")

    assert {:ok, {:reject, [piece: 3]}} =
             Magnet.UtMetadata.decode_message("d8:msg_typei2e5:piecei3ee")

    data = <<1, 2, 3>>
    dict = Bento.encode!(%{"msg_type" => 1, "piece" => 0, "total_size" => byte_size(data)})

    assert {:ok, {:data, [piece: 0, total_size: 3, data: ^data]}} =
             Magnet.UtMetadata.decode_message(dict <> data)
  end

  test "parse_extension_handshake reads ut_metadata id and metadata_size" do
    handshake = %{
      "m" => %{"ut_metadata" => 3},
      "metadata_size" => 31_235
    }

    assert %{
             ut_metadata_id: 3,
             metadata_size: 31_235
           } = Magnet.UtMetadata.parse_extension_handshake(handshake)

    assert %{ut_metadata_id: nil, metadata_size: nil} =
             Magnet.UtMetadata.parse_extension_handshake(%{"m" => %{}})
  end

  test "assemble_pieces rebuilds metadata and rejects wrong lengths" do
    total = @block + 10
    pieces = %{0 => :binary.copy(<<0>>, @block), 1 => :binary.copy(<<1>>, 10)}

    assert {:ok, blob} = Magnet.UtMetadata.assemble_pieces(pieces, total)
    assert byte_size(blob) == total

    assert {:error, :incomplete} =
             Magnet.UtMetadata.assemble_pieces(Map.delete(pieces, 1), total)
  end

  test "decode_and_verify_info checks SHA-1 of bencoded info dict" do
    info = %{"name" => "example", "piece length" => @block, "pieces" => <<0::160>>}
    encoded = Bento.encode!(info)
    hash = :crypto.hash(:sha, encoded)

    assert {:ok, ^info, ^encoded} = Magnet.UtMetadata.decode_and_verify_info(encoded, hash)

    assert {:error, :info_hash_mismatch} =
             Magnet.UtMetadata.decode_and_verify_info(encoded, <<0::160>>)

    assert {:error, :info_hash_mismatch} =
             Magnet.UtMetadata.decode_and_verify_info(<<0, encoded::binary>>, hash)
  end
end

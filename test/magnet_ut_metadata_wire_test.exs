defmodule Magnet.UtMetadataWireTest do
  use ExUnit.Case, async: true

  alias Peer.LTEP.Handshake

  test "request_piece sends on peer ut_metadata id and reads reply on local id" do
    peer_hs = %Handshake{m: %{"ut_metadata" => 7}, metadata_size: 100}
    ltep = Peer.LTEP.Session.new() |> Peer.LTEP.Session.apply_peer_handshake(peer_hs)

    assert Peer.LTEP.Session.peer_extension_id(ltep, "ut_metadata") == 7
    assert Peer.LTEP.Session.local_extension_id(ltep, "ut_metadata") == 1

    request = Magnet.UtMetadata.encode_request(0)
    data = Magnet.UtMetadata.encode_data(0, 100, :binary.copy(<<9>>, 100))

    wire_req = Peer.LTEP.extended_message_wire(7, request)
    wire_data = Peer.LTEP.extended_message_wire(1, data)

    assert <<_len::32, 20, 7, ^request::binary>> = wire_req
    assert <<_len::32, 20, 1, ^data::binary>> = wire_data
  end

  test "decode_message splits bencode header from trailing metadata bytes for single-piece torrents" do
    total_size = 3305
    piece_data = :crypto.strong_rand_bytes(total_size)
    payload = Magnet.UtMetadata.encode_data(0, total_size, piece_data)

    assert {:ok, {:data, [piece: 0, total_size: ^total_size, data: ^piece_data]}} =
             Magnet.UtMetadata.decode_message(payload)

    assert byte_size(piece_data) == Magnet.UtMetadata.piece_byte_size(total_size, 0)
    assert Magnet.UtMetadata.piece_count(total_size) == 1
  end

  test "split_bencoded_prefix leaves binary metadata blob intact when it starts with d" do
    total_size = 3305
    piece_data = :crypto.strong_rand_bytes(total_size)
    payload = Magnet.UtMetadata.encode_data(0, total_size, piece_data)

    assert {:ok, dict, rest} = Magnet.UtMetadata.split_bencoded_prefix(payload)
    assert dict["msg_type"] == 1
    assert dict["piece"] == 0
    assert dict["total_size"] == total_size
    assert rest == piece_data
  end
end

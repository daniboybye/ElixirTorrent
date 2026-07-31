defmodule PeerSenderWireTest do
  use ExUnit.Case, async: true

  test "known_wire_id?/1 covers core + DHT port + Fast + LTEP + BEP 52 hash transfer" do
    for id <- [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 20, 21, 22, 23] do
      assert Peer.Sender.known_wire_id?(id)
    end
  end

  test "known_wire_id?/1 rejects other future ids" do
    refute Peer.Sender.known_wire_id?(18)
    refute Peer.Sender.known_wire_id?(255)
  end

  test "global wire ceiling stays strictly above every per-id cap" do
    ceiling = Peer.Sender.max_wire_message_size()

    # The global ceiling runs before the per-id caps in take_message/1, so it must
    # never be the tighter of the two — otherwise raising a per-id cap silently stops
    # working. Strictly greater, not >=: LTEP's 1 MiB is the largest legitimate frame
    # and an equal ceiling would leave it no headroom at all.
    for cap <- [
          Peer.LTEP.max_message_size(),
          Peer.Sender.max_bitfield_message_size(),
          Peer.HashWire.max_hashes_message_size(),
          1 + Peer.HashWire.header_size(),
          2 + Magnet.UtMetadata.max_message_payload_size(),
          9 + Torrent.Downloads.piece_max_length()
        ] do
      assert cap < ceiling
    end
  end
end

defmodule PeerSenderWireTest do
  use ExUnit.Case, async: true

  test "known_wire_id?/1 covers core + DHT port + Fast + LTEP" do
    for id <- [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 20] do
      assert Peer.Sender.known_wire_id?(id)
    end
  end

  test "known_wire_id?/1 rejects BEP 52 hash_* and other future ids" do
    # BEP 52 § hash messages — must be ignored until phase 4 implements them,
    # not treated as protocol_error (would kill the peer under one_for_all).
    refute Peer.Sender.known_wire_id?(21)
    refute Peer.Sender.known_wire_id?(22)
    refute Peer.Sender.known_wire_id?(23)
    refute Peer.Sender.known_wire_id?(18)
    refute Peer.Sender.known_wire_id?(255)
  end
end

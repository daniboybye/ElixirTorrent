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
end

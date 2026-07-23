defmodule PeerReservedTest do
  use ExUnit.Case, async: true

  describe "v2_support?/1 (BEP 52 reserved bit)" do
    test "reads the fourth most significant bit of the last reserved byte" do
      reserved = <<0, 0, 0, 0, 0, 0, 0, 0x10>>

      assert Peer.v2_support?(reserved)
      refute Peer.dht?(reserved)
      refute Peer.fast_extension?(reserved)
      refute Peer.extension_protocol?(reserved)
    end

    test "does not confuse the v2 bit with LTEP, DHT, or Fast Extension bits" do
      refute Peer.v2_support?(<<0::64>>)
      refute Peer.v2_support?(<<0, 0, 0, 0, 0, 0x10, 0, 0>>)
      refute Peer.v2_support?(<<0, 0, 0, 0, 0, 0, 0, 0x05>>)
      refute Peer.v2_support?(<<0, 0, 0, 0, 0, 0, 0, 0x08>>)
      refute Peer.v2_support?(<<0, 0, 0, 0, 0, 0, 0, 0x20>>)
    end

    test "coexists with DHT and Fast Extension bits in the last byte" do
      reserved = <<0, 0, 0, 0, 0, 0, 0, 0x15>>

      assert Peer.v2_support?(reserved)
      assert Peer.dht?(reserved)
      assert Peer.fast_extension?(reserved)
    end

    test "our handshake advertises BEP 52 v2 support alongside DHT and Fast" do
      assert Peer.reserved() == <<0, 0, 0, 0, 0, 0x10, 0, 0x15>>
      assert Peer.v2_support?(Peer.reserved())
      assert Peer.dht?(Peer.reserved())
      assert Peer.fast_extension?(Peer.reserved())
    end
  end
end

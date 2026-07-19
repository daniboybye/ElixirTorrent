defmodule UTPPacketTest do
  use ExUnit.Case, async: true

  alias UTP.Packet

  test "encode/decode round-trip ST_DATA without extensions" do
    header = %Packet{
      type: Packet.st_data(),
      version: 1,
      extension: 0,
      conn_id: 12_345,
      timestamp: 987_654_321,
      timestamp_difference: 42_000,
      wnd_size: 65_535,
      seq_nr: 7,
      ack_nr: 6
    }

    payload = <<1, 2, 3, 4>>
    bin = Packet.encode(header, payload)

    assert byte_size(bin) == Packet.header_size() + byte_size(payload)
    assert {:ok, decoded, decoded_payload, extensions} = Packet.decode(bin)
    assert decoded_payload == payload
    assert extensions == []
    assert decoded.type == header.type
    assert decoded.conn_id == header.conn_id
    assert decoded.timestamp == header.timestamp
    assert decoded.seq_nr == header.seq_nr
    assert decoded.ack_nr == header.ack_nr
  end

  test "encode/decode ST_SYN with version nibble" do
    header = %Packet{
      type: Packet.st_syn(),
      version: 1,
      extension: 0,
      conn_id: 100,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 0,
      seq_nr: 1,
      ack_nr: 0
    }

    bin = Packet.encode(header, <<>>)
    assert Packet.utp_packet?(bin)
    assert {:ok, decoded, <<>>, _} = Packet.decode(bin)
    assert decoded.type == Packet.st_syn()
  end

  test "selective ACK extension decode and ack list" do
    # Bitmask acks ack_nr+2 (one bit set in first byte, LSB = ack_nr+2)
    bitmask = <<0x01, 0x00, 0x00, 0x00>>

    header = %Packet{
      type: Packet.st_state(),
      version: 1,
      extension: 1,
      conn_id: 50,
      timestamp: 10,
      timestamp_difference: 0,
      wnd_size: 1000,
      seq_nr: 5,
      ack_nr: 10,
      extensions: [{:selective_ack, bitmask}]
    }

    bin = Packet.encode(header, <<>>)
    assert byte_size(bin) == Packet.header_size() + 6

    assert {:ok, decoded, <<>>, extensions} = Packet.decode(bin)
    assert {:selective_ack, ^bitmask} = hd(extensions)
    assert Packet.selective_ack_acks(decoded, extensions) == [Packet.seq_add(10, 2)]
  end

  test "seq arithmetic wraps at 16 bits" do
    assert Packet.seq_add(65535, 1) == 0
    assert Packet.seq_before?(5, 10)
    assert Packet.seq_after?(10, 5)
  end
end

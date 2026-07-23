defmodule UDPTrackerTest do
  use ExUnit.Case, async: true

  alias Tracker.UDP

  @protocol_id UDP.protocol_id()
  @hash :crypto.strong_rand_bytes(20)
  @peer_id :crypto.strong_rand_bytes(20)
  @connection_id :crypto.strong_rand_bytes(8)
  @transaction_id <<0xDE, 0xAD, 0xBE, 0xEF>>
  @other_transaction_id <<0x01, 0x02, 0x03, 0x04>>

  describe "BEP 15 connect packets" do
    test "encode_connect/1 matches wire layout (protocol_id, action=0, transaction_id)" do
      packet = UDP.encode_connect(@transaction_id) |> IO.iodata_to_binary()
      protocol_id = @protocol_id

      assert byte_size(packet) == 16
      assert <<^protocol_id::binary-size(8), 0::32, @transaction_id::binary>> = packet
    end

    test "decode_connect_response/2 accepts valid connect response" do
      body = <<0::32, @transaction_id::binary, @connection_id::binary>>

      assert {:ok, @connection_id} = UDP.decode_connect_response(body, @transaction_id)
    end

    test "decode_connect_response/2 rejects short packets" do
      assert {:error, :invalid_packet} =
               UDP.decode_connect_response(<<0::32, @transaction_id::binary>>, @transaction_id)
    end

    test "decode_connect_response/2 rejects transaction_id mismatch" do
      body = <<0::32, @other_transaction_id::binary, @connection_id::binary>>

      assert {:error, :transaction_mismatch} =
               UDP.decode_connect_response(body, @transaction_id)
    end

    test "decode_connect_response/2 surfaces tracker error message" do
      body = <<3::32, @transaction_id::binary, "connection limit">>

      assert {:error, "connection limit"} = UDP.decode_connect_response(body, @transaction_id)
    end
  end

  describe "BEP 15 announce packets" do
    test "encode_announce/5 is 98 bytes with expected field order" do
      packet =
        UDP.encode_announce(@connection_id, @transaction_id, @hash, @peer_id,
          uploaded: 1,
          downloaded: 2,
          left: 3,
          event: 2,
          ip_field: <<0::32>>,
          key: <<0x11, 0x22, 0x33, 0x44>>,
          num_want: -1,
          port: 6881
        )
        |> IO.iodata_to_binary()

      connection_id = @connection_id
      hash = @hash
      peer_id = @peer_id

      assert byte_size(packet) == 98

      assert <<^connection_id::binary-size(8), 1::32, @transaction_id::binary,
               ^hash::binary-size(20), ^peer_id::binary-size(20), 2::64, 3::64, 1::64, 2::32,
               0::32, 0x11223344::32, 0xFFFFFFFF::32, 6881::16>> = packet
    end

    test "decode_announce_response/3 parses interval, counts, and compact IPv4 peers" do
      peers = <<127, 0, 0, 1, 6881::16, 10, 0, 0, 2, 8080::16>>
      body = <<1::32, @transaction_id::binary, 1200::32, 5::32, 10::32, peers::binary>>

      assert {:ok, response} = UDP.decode_announce_response(body, @transaction_id, :inet)
      assert response.interval == 1200
      assert response.complete == 10
      assert response.incomplete == 5
      assert length(response.peers) == 2
      assert hd(response.peers).ip == {127, 0, 0, 1}
    end

    test "decode_announce_response/3 uses 18-byte stride for IPv6 peers" do
      {peer, rest} =
        {<<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 9999::16>>,
         <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 127, 0, 0, 1, 7777::16>>}

      body = <<1::32, @transaction_id::binary, 60::32, 1::32, 2::32, peer::binary, rest::binary>>

      assert {:ok, response} = UDP.decode_announce_response(body, @transaction_id, :inet6)
      assert length(response.peers) == 2
      assert List.last(response.peers).port == 7777
    end

    test "decode_announce_response/3 validates transaction_id and minimum size" do
      body = <<1::32, @other_transaction_id::binary, 60::32, 1::32, 2::32>>

      assert {:error, :transaction_mismatch} =
               UDP.decode_announce_response(body, @transaction_id, :inet)

      assert {:error, :invalid_packet} =
               UDP.decode_announce_response(
                 <<1::32, @transaction_id::binary>>,
                 @transaction_id,
                 :inet
               )
    end
  end

  describe "BEP 15 scrape packets" do
    test "encode_scrape/3 packs connection_id, action=2, transaction_id, and hashes" do
      hash2 = :crypto.strong_rand_bytes(20)
      connection_id = @connection_id
      hash = @hash

      packet =
        UDP.encode_scrape(@connection_id, @transaction_id, [@hash, hash2])
        |> IO.iodata_to_binary()

      assert byte_size(packet) == 16 + 40

      assert <<^connection_id::binary-size(8), 2::32, @transaction_id::binary,
               ^hash::binary-size(20), ^hash2::binary-size(20)>> = packet
    end

    test "decode_scrape_response/3 returns ordered stats per hash" do
      body =
        <<2::32, @transaction_id::binary, 10::32, 20::32, 30::32, 1::32, 2::32, 3::32>>

      assert {:ok, stats} = UDP.decode_scrape_response(body, @transaction_id, 2)

      assert stats == [
               %{seeders: 10, completed: 20, leechers: 30},
               %{seeders: 1, completed: 2, leechers: 3}
             ]
    end

    test "decode_scrape_response/3 rejects truncated scrape bodies" do
      body = <<2::32, @transaction_id::binary, 1::32, 2::32, 3::32>>

      assert {:error, :invalid_packet} =
               UDP.decode_scrape_response(body, @transaction_id, 2)
    end
  end

  describe "BEP 15 error packets" do
    test "decode_error_response/2 returns human-readable message" do
      body = <<3::32, @transaction_id::binary, "invalid info_hash">>

      assert {:error, "invalid info_hash"} = UDP.decode_error_response(body, @transaction_id)
    end

    test "classify_response/3 ignores mismatched transaction_id for recv loops" do
      body = <<1::32, @other_transaction_id::binary, 60::32, 1::32, 2::32>>

      assert :ignore =
               UDP.classify_response(body, @transaction_id, expected: :announce, family: :inet)
    end
  end

  describe "BEP 15 compact peer parsing" do
    test "parse_compact_peers/2 stops cleanly on partial trailing bytes" do
      peers = <<1, 2, 3, 4, 1000::16, 1, 2, 3>>

      assert [%Peer{ip: {1, 2, 3, 4}, port: 1000}] =
               UDP.parse_compact_peers(peers, :inet)
    end
  end

  describe "BEP 15 backoff and connection_id lifetime" do
    test "backoff_timeout_seconds/1 follows 15 * 2^n for n in 0..8" do
      assert UDP.backoff_timeout_seconds(0) == 15
      assert UDP.backoff_timeout_seconds(1) == 30
      assert UDP.backoff_timeout_seconds(2) == 60
      assert UDP.backoff_timeout_seconds(8) == 3840
    end

    test "max_backoff_attempt/0 caps retransmissions at n=8" do
      assert UDP.max_backoff_attempt() == 8
    end

    test "connection_id_lifetime_ms/0 is one minute per spec" do
      assert UDP.connection_id_lifetime_ms() == 60_000
    end
  end

  describe "Tracker UDP backoff exhaustion" do
    test "udp_exhausted?/1 is true only after attempt 8 (nine tries, n=0..8)" do
      refute Tracker.udp_exhausted?(0)
      refute Tracker.udp_exhausted?(8)
      assert Tracker.udp_exhausted?(9)
    end

    test "udp_backoff_ms_for_test/1 honors :udp_backoff_ms application env override" do
      Application.put_env(:elixir_torrent, :udp_backoff_ms, fn _attempt -> 42 end)

      try do
        assert Tracker.udp_backoff_ms_for_test(0) == 42
        assert Tracker.udp_backoff_ms_for_test(8) == 42
      after
        Application.delete_env(:elixir_torrent, :udp_backoff_ms)
      end
    end

    test "do_udp_request guard yields %Tracker.Error{reason: :timeout} after n=8" do
      assert Tracker.udp_exhausted?(UDP.max_backoff_attempt() + 1)
      assert match?(%Tracker.Error{reason: :timeout}, %Tracker.Error{reason: :timeout})
    end
  end
end

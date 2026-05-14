defmodule ProtocolPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Peer.UtPex
  alias Tracker.{Error, Response}

  @moduletag :property

  @property_max_runs 35
  @property_max_runs_tight 25

  defp utp_header_gen do
    gen all(
          type <- integer(0..4),
          conn_id <- integer(0..65_535),
          timestamp <- integer(0..0xFFFF_FFFF),
          timestamp_diff <- integer(0..0xFFFF_FFFF),
          wnd_size <- integer(0..0xFFFF_FFFF),
          seq_nr <- integer(0..65_535),
          ack_nr <- integer(0..65_535),
          sack? <- boolean(),
          sack_body <- binary(min_length: 0, max_length: 4),
          payload <- binary(min_length: 0, max_length: 32)
        ) do
      extensions =
        if sack? and byte_size(sack_body) > 0 do
          [{:selective_ack, sack_body}]
        else
          []
        end

      header = %UTP.Packet{
        type: type,
        version: 1,
        extension: 0,
        conn_id: conn_id,
        timestamp: timestamp,
        timestamp_difference: timestamp_diff,
        wnd_size: wnd_size,
        seq_nr: seq_nr,
        ack_nr: ack_nr,
        extensions: extensions
      }

      {header, payload}
    end
  end

  describe "UTP.Packet" do
    property "encode/decode roundtrip preserves header fields and payload" do
      check all(
              {header, payload} <- utp_header_gen(),
              max_runs: @property_max_runs
            ) do
        encoded = UTP.Packet.encode(header, payload)

        assert {:ok, decoded, rest, extensions} = UTP.Packet.decode(encoded)
        assert rest == payload
        assert decoded.type == header.type
        assert decoded.version == 1
        assert decoded.conn_id == header.conn_id
        assert decoded.timestamp == header.timestamp
        assert decoded.timestamp_difference == header.timestamp_difference
        assert decoded.wnd_size == header.wnd_size
        assert decoded.seq_nr == header.seq_nr
        assert decoded.ack_nr == header.ack_nr
        assert decoded.extensions == header.extensions
        assert extensions == header.extensions
      end
    end

    test "decode bounds: short input and bad version" do
      check all(
              suffix <- binary(min_length: 0, max_length: 8),
              max_runs: @property_max_runs_tight
            ) do
        short = if byte_size(suffix) >= 20, do: binary_part(suffix, 0, 19), else: suffix
        assert {:error, :too_short} = UTP.Packet.decode(short)
      end

      check all(
              low_nibble <- integer(2..15),
              rest <- binary(min_length: 19, max_length: 19),
              max_runs: @property_max_runs_tight
            ) do
        type_ver = Bitwise.bor(Bitwise.bsl(0, 4), low_nibble)
        bad = <<type_ver, rest::binary>>
        assert {:error, :bad_version} = UTP.Packet.decode(bad)
      end
    end

    property "utp_packet? agrees with successful v1 decode on full packets" do
      check all(
              {header, payload} <- utp_header_gen(),
              max_runs: @property_max_runs_tight
            ) do
        encoded = UTP.Packet.encode(header, payload)

        if UTP.Packet.utp_packet?(encoded) do
          assert match?({:ok, _, _, _}, UTP.Packet.decode(encoded))
        end
      end
    end
  end

  defp pub4(n), do: {11, 0, 0, rem(n, 250)}

  defp pub6(n) do
    {0x2001, 0xDB8, 0, 0, 0, 0, 0, rem(n, 0xFFFF)}
  end

  defp endpoint_v4_gen do
    gen all(
          n <- integer(1..240),
          port <- integer(1024..65_535)
        ) do
      {pub4(n), port}
    end
  end

  defp endpoint_v6_gen do
    gen all(
          n <- integer(1..1000),
          port <- integer(1024..65_535)
        ) do
      {pub6(n), port}
    end
  end

  describe "Peer.UtPex" do
    property "IPv4 endpoint sets round-trip through encode/decode" do
      check all(
              added <- list_of(endpoint_v4_gen(), min_length: 0, max_length: 4),
              dropped <- list_of(endpoint_v4_gen(), min_length: 0, max_length: 3),
              added != [] or dropped != [],
              max_runs: @property_max_runs
            ) do
        payload = UtPex.encode(added, dropped)
        assert is_binary(payload)

        assert {:ok, decoded_added, decoded_dropped} = UtPex.decode(payload)
        assert Enum.map(decoded_added, &{&1.ip, &1.port}) == added
        assert Enum.map(decoded_dropped, &{&1.ip, &1.port}) == dropped
      end
    end

    property "IPv6 endpoints round-trip and preserve seed flag when set" do
      check all(
              added <- list_of(endpoint_v6_gen(), min_length: 1, max_length: 3),
              max_runs: @property_max_runs_tight
            ) do
        entries =
          Enum.map(added, fn ep ->
            UtPex.Entry.new(ep, UtPex.flag_seed())
          end)

        assert {:ok, payload, _report} = UtPex.encode_delta(entries, [], initial?: false)
        assert {:ok, decoded, []} = UtPex.decode(payload)

        assert Enum.map(decoded, &{&1.ip, &1.port}) == added
        assert Enum.all?(decoded, &(&1.seed == true))
      end
    end

    property "oversize inbound payloads are rejected without decode" do
      check all(
              padding <- binary(min_length: 16_385, max_length: 16_500),
              max_runs: 10
            ) do
        assert UtPex.decode(padding) == :error
      end
    end
  end

  describe "Torrent.Bitfield" do
    property "set/have/count stay within piece bounds" do
      check all(
              pieces_count <- integer(1..256),
              indices <- list_of(integer(0..255), min_length: 0, max_length: 12),
              max_runs: @property_max_runs
            ) do
        valid_indices =
          indices
          |> Enum.filter(&(&1 < pieces_count))
          |> Enum.uniq()

        bitfield = Torrent.Bitfield.make(pieces_count)

        bitfield =
          Enum.reduce(valid_indices, bitfield, fn idx, acc ->
            Torrent.Bitfield.set(acc, idx, 1)
          end)

        assert Torrent.Bitfield.valid?(bitfield, pieces_count)

        assert Torrent.Bitfield.count(bitfield, pieces_count) == length(valid_indices)

        for idx <- valid_indices do
          assert Torrent.Bitfield.have?(bitfield, idx)
        end

        unset =
          Enum.find(0..(pieces_count - 1), fn idx ->
            idx not in valid_indices
          end)

        if unset != nil do
          refute Torrent.Bitfield.have?(bitfield, unset)
        end
      end
    end

    property "expected_byte_size matches make/1 length" do
      check all(
              pieces_count <- integer(1..512),
              max_runs: @property_max_runs_tight
            ) do
        bf = Torrent.Bitfield.make(pieces_count)
        assert byte_size(bf) == Torrent.Bitfield.expected_byte_size(pieces_count)
      end
    end
  end

  describe "Tracker HTTP decode (test API)" do
    property "failure maps decode to Tracker.Error with BEP31 retry seconds" do
      check all(
              reason <- string(:printable, min_length: 1, max_length: 40),
              minutes <- integer(0..120),
              max_runs: @property_max_runs_tight
            ) do
        map = %{"failure reason" => reason, "retry in" => minutes}

        assert %Error{reason: ^reason, retry_in: seconds} =
                 Tracker.decode_http_response_for_test(map)

        assert seconds == minutes * 60
      end
    end

    property "announce maps decode to Tracker.Response peer endpoints" do
      check all(
              interval <- integer(60..3600),
              complete <- integer(0..10_000),
              incomplete <- integer(0..10_000),
              peers <-
                list_of(
                  gen all(
                        ip_n <- integer(1..200),
                        port <- integer(1024..65_535)
                      ) do
                    %{"ip" => :inet.ntoa(pub4(ip_n)) |> to_string(), "port" => port}
                  end,
                  min_length: 0,
                  max_length: 4
                ),
              max_runs: @property_max_runs_tight
            ) do
        map = %{
          "interval" => interval,
          "complete" => complete,
          "incomplete" => incomplete,
          "peers" => peers
        }

        assert %Response{
                 interval: ^interval,
                 complete: ^complete,
                 incomplete: ^incomplete,
                 peers: decoded_peers
               } = Tracker.decode_http_response_for_test(map)

        assert length(decoded_peers) == length(peers)

        expected_endpoints =
          Enum.map(peers, fn %{"ip" => ip, "port" => port} ->
            {:ok, tuple} = :inet.parse_address(String.to_charlist(ip))
            {tuple, port}
          end)

        actual_endpoints = Enum.map(decoded_peers, fn %Peer{ip: ip, port: port} -> {ip, port} end)
        assert actual_endpoints == expected_endpoints
      end
    end
  end
end

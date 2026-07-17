defmodule DHTCompactTest do
  use ExUnit.Case, async: true

  alias DHT.Compact

  @node_id :crypto.strong_rand_bytes(20)
  @ip {192, 168, 1, 1}
  @port 6881

  describe "compact node info (BEP 5 § Contact Encoding)" do
    test "encode_node/3 produces 26 bytes (id + ipv4 + port)" do
      node_id = @node_id
      encoded = Compact.encode_node(node_id, @ip, @port)
      assert byte_size(encoded) == 26
      assert <<^node_id::binary-size(20), 192, 168, 1, 1, 6881::16>> = encoded
    end

    test "decode_nodes/1 round-trips a single node" do
      node_id = @node_id
      encoded = Compact.encode_node(node_id, @ip, @port)
      assert [%{id: ^node_id, ip: @ip, port: @port}] = Compact.decode_nodes(encoded)
    end

    test "encode_nodes/1 concatenates multiple entries" do
      id2 = :crypto.strong_rand_bytes(20)
      nodes = [%{id: @node_id, ip: @ip, port: @port}, %{id: id2, ip: {10, 0, 0, 2}, port: 8080}]
      encoded = Compact.encode_nodes(nodes)
      assert byte_size(encoded) == 52
      assert length(Compact.decode_nodes(encoded)) == 2
    end

    test "decode_nodes/1 ignores trailing partial bytes" do
      encoded = Compact.encode_node(@node_id, @ip, @port) <> <<1, 2, 3>>
      assert length(Compact.decode_nodes(encoded)) == 1
    end
  end

  describe "compact peer info (BEP 23)" do
    test "encode_peer/2 produces 6 bytes" do
      encoded = Compact.encode_peer(@ip, @port)
      assert byte_size(encoded) == 6
      assert <<192, 168, 1, 1, 6881::16>> = encoded
    end

    test "decode_peers/1 round-trips" do
      encoded = Compact.encode_peer(@ip, @port)
      assert [%Peer{ip: @ip, port: @port}] = Compact.decode_peers(encoded)
    end
  end
end

defmodule DHTKRPCTest do
  use ExUnit.Case, async: true

  alias DHT.{Compact, KRPC}

  @tid <<0xAA, 0xBB>>
  @query_id :crypto.strong_rand_bytes(20)
  @response_id :crypto.strong_rand_bytes(20)
  @target_id :crypto.strong_rand_bytes(20)
  @info_hash :crypto.strong_rand_bytes(20)
  @token "aoeusnth"
  @version "ET01"

  describe "KRPC queries (BEP 5 § DHT Queries)" do
    test "ping query round-trip" do
      query = %{method: :ping, transaction_id: @tid, node_id: @query_id, version: @version}
      packet = KRPC.encode_query(query)
      assert {:ok, {:query, decoded}} = KRPC.decode(packet)
      assert decoded.method == :ping
      assert decoded.transaction_id == @tid
      assert decoded.node_id == @query_id
      assert decoded.version == @version
    end

    test "find_node query round-trip" do
      query = %{
        method: :find_node,
        transaction_id: @tid,
        node_id: @query_id,
        target: @target_id
      }

      assert {:ok, {:query, decoded}} = query |> KRPC.encode_query() |> KRPC.decode()
      assert decoded.method == :find_node
      assert decoded.target == @target_id
    end

    test "get_peers query round-trip" do
      query = %{
        method: :get_peers,
        transaction_id: @tid,
        node_id: @query_id,
        info_hash: @info_hash
      }

      assert {:ok, {:query, decoded}} = query |> KRPC.encode_query() |> KRPC.decode()
      assert decoded.method == :get_peers
      assert decoded.info_hash == @info_hash
    end

    test "announce_peer query round-trip with implied_port" do
      query = %{
        method: :announce_peer,
        transaction_id: @tid,
        node_id: @query_id,
        info_hash: @info_hash,
        port: 6881,
        token: @token,
        implied_port: 1
      }

      assert {:ok, {:query, decoded}} = query |> KRPC.encode_query() |> KRPC.decode()
      assert decoded.method == :announce_peer
      assert decoded.implied_port == 1
      assert decoded.token == @token
    end
  end

  describe "KRPC responses" do
    test "ping response round-trip" do
      response = %{transaction_id: @tid, node_id: @response_id}
      assert {:ok, {:response, decoded}} = response |> KRPC.encode_response() |> KRPC.decode()
      assert decoded.node_id == @response_id
    end

    test "get_peers response with values and token" do
      peer_blob = Compact.encode_peer({127, 0, 0, 1}, 6881)

      response = %{
        transaction_id: @tid,
        node_id: @response_id,
        token: @token,
        values: [peer_blob]
      }

      assert {:ok, {:response, decoded}} = response |> KRPC.encode_response() |> KRPC.decode()
      assert decoded.token == @token
      assert KRPC.response_peers(decoded) == [%Peer{ip: {127, 0, 0, 1}, port: 6881}]
    end

    test "get_peers response with closest nodes" do
      nodes = Compact.encode_nodes([%{id: @target_id, ip: {10, 0, 0, 1}, port: 6881}])

      response = %{
        transaction_id: @tid,
        node_id: @response_id,
        token: @token,
        nodes: nodes
      }

      assert {:ok, {:response, decoded}} = response |> KRPC.encode_response() |> KRPC.decode()

      assert KRPC.response_nodes(decoded) == [
               %{id: @target_id, ip: {10, 0, 0, 1}, port: 6881}
             ]
    end
  end

  describe "KRPC errors (BEP 5 § Errors)" do
    test "error packet round-trip" do
      error = %{transaction_id: @tid, code: 203, message: "Protocol Error"}
      assert {:ok, {:error, decoded}} = error |> KRPC.encode_error() |> KRPC.decode()
      assert decoded.code == 203
      assert decoded.message == "Protocol Error"
    end

    test "decode/1 rejects malformed packets" do
      assert {:error, _} = KRPC.decode("not bencode")
      assert {:error, _} = KRPC.decode(Bento.encode!(%{"y" => "q"}))
    end
  end
end

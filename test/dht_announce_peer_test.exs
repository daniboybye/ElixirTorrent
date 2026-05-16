defmodule DHT.AnnouncePeerTest do
  use ExUnit.Case, async: true

  alias DHT.{Compact, KRPC, PeerStore, RoutingTables, Token}

  @local_id <<0::160>>
  @query_id <<1::160>>
  @info_hash <<51::160>>

  setup do
    {:ok, server} =
      :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])

    {:ok, client} =
      :gen_udp.open(0, [:binary, :inet, active: false, ip: {127, 0, 0, 1}])

    on_exit(fn ->
      :gen_udp.close(server)
      :gen_udp.close(client)
    end)

    state = %DHT{
      socket_v4: server,
      socket_v6: nil,
      node_id: @local_id,
      routing_tables: RoutingTables.new(@local_id),
      tokens: Token.new(),
      peer_store: %{}
    }

    %{state: state, server: server, client: client}
  end

  test "get_peers token + announce_peer implied_port round-trip stores and returns peer",
       context do
    {token, state} = get_peers_token(context)
    {:ok, {source_ip, source_port}} = :inet.sockname(context.client)

    announce_query = %{
      method: :announce_peer,
      transaction_id: <<0x01>>,
      node_id: @query_id,
      info_hash: @info_hash,
      token: token,
      port: 6_881,
      implied_port: 1
    }

    {announce_response, state} =
      send_query(context, state, announce_query, :response)

    assert announce_response.node_id == @local_id
    assert announce_response.values == nil

    assert [%Peer{ip: ^source_ip, port: ^source_port}] =
             PeerStore.get(state.peer_store, @info_hash)

    {get_peers_response, _state} =
      send_query(
        context,
        state,
        get_peers_query(<<0x02>>),
        :response
      )

    assert [%Peer{ip: ^source_ip, port: ^source_port}] =
             KRPC.response_peers(get_peers_response)
  end

  test "announce_peer with invalid token returns 203 and does not store peer", context do
    {_token, state} = get_peers_token(context)
    peers_before = PeerStore.get(state.peer_store, @info_hash)

    bad_token = :binary.copy(<<0xFF>>, 8)

    announce_query = %{
      method: :announce_peer,
      transaction_id: <<0x03>>,
      node_id: @query_id,
      info_hash: @info_hash,
      token: bad_token,
      port: 6_881,
      implied_port: 1
    }

    {error, state} = send_query(context, state, announce_query, :error)

    assert error.code == 203
    assert error.message == "invalid token or arguments"
    assert PeerStore.get(state.peer_store, @info_hash) == peers_before
  end

  test "announce_peer with out-of-range port returns 203 and does not store peer", context do
    {token, state} = get_peers_token(context)
    peers_before = PeerStore.get(state.peer_store, @info_hash)

    announce_query = %{
      method: :announce_peer,
      transaction_id: <<0x04>>,
      node_id: @query_id,
      info_hash: @info_hash,
      token: token,
      port: 0
    }

    {error, state} = send_query(context, state, announce_query, :error)

    assert error.code == 203
    assert error.message == "invalid token or arguments"
    assert PeerStore.get(state.peer_store, @info_hash) == peers_before
  end

  test "announce_peer without port or implied_port returns 203 Protocol Error and does not store",
       context do
    peers_before = PeerStore.get(context.state.peer_store, @info_hash)
    {:ok, {source_ip, source_port}} = :inet.sockname(context.client)

    packet =
      Bento.encode!(%{
        "t" => <<0x05>>,
        "y" => "q",
        "q" => "announce_peer",
        "a" => %{
          "id" => @query_id,
          "info_hash" => @info_hash,
          "token" => :binary.copy(<<0xAB>>, 8)
        }
      })

    {error, state} =
      send_raw_packet(context, context.state, packet, source_ip, source_port, :error)

    assert error.code == 203
    assert error.message == "Protocol Error"
    assert PeerStore.get(state.peer_store, @info_hash) == peers_before
  end

  defp get_peers_token(context) do
    {response, state} =
      send_query(context, context.state, get_peers_query(<<0x00>>), :response)

    assert is_binary(response.token)
    {response.token, state}
  end

  defp get_peers_query(tid) do
    %{
      method: :get_peers,
      transaction_id: tid,
      node_id: @query_id,
      info_hash: @info_hash
    }
  end

  defp send_query(context, state, query, expect) do
    {:ok, {source_ip, source_port}} = :inet.sockname(context.client)
    packet = KRPC.encode_query(query)
    send_raw_packet(context, state, packet, source_ip, source_port, expect)
  end

  defp send_raw_packet(context, state, packet, source_ip, source_port, expect) do
    assert {:noreply, new_state} =
             DHT.handle_info(
               {:udp, context.server, source_ip, source_port, packet},
               state
             )

    assert {:ok, {_server_ip, _server_port, response_packet}} =
             :gen_udp.recv(context.client, 0, 1_000)

    decoded =
      case expect do
        :response ->
          assert {:ok, {:response, response}} = KRPC.decode(response_packet)
          assert response.ip == Compact.encode_peer(source_ip, source_port)
          response

        :error ->
          assert {:ok, {:error, error}} = KRPC.decode(response_packet)
          assert error.ip == Compact.encode_peer(source_ip, source_port)
          error
      end

    {decoded, new_state}
  end
end

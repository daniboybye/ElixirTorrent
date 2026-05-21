defmodule Peer.MSE.HandshakeTest do
  use ExUnit.Case, async: true

  alias Peer.MSE
  alias Peer.MSE.Handshake

  @timeout 5_000

  # Run initiator and responder against each other over a real loopback TCP pair.
  defp run_handshake(info_hash, ia, candidate_hashes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = spawn_mse_responder(listen, candidate_hashes, self())
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)
    client_result = Handshake.initiate(client, info_hash, ia, @timeout)
    server_result = await_mse_server_result(@timeout)
    :gen_tcp.close(listen)
    {client, client_result, server_result, server}
  end

  defp spawn_mse_responder(listen, candidate_hashes, parent) do
    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, @timeout)
      result = Handshake.respond(sock, Handshake.resolver(candidate_hashes), @timeout)
      send(parent, {:server, result, sock})

      # hold the socket open so the caller can exchange test bytes
      receive do
        :close -> :gen_tcp.close(sock)
      after
        @timeout -> :gen_tcp.close(sock)
      end
    end)
  end

  defp await_mse_server_result(timeout) do
    receive do
      {:server, r, sock} -> {r, sock}
    after
      timeout -> flunk("responder did not finish")
    end
  end

  test "initiator and responder complete the handshake and recover the IA payload" do
    info_hash = :crypto.strong_rand_bytes(20)
    ia = "\x13BitTorrent protocol" <> :crypto.strong_rand_bytes(48)

    {client, client_result, {server_result, ssock}, server} =
      run_handshake(info_hash, ia, [:crypto.strong_rand_bytes(20), info_hash])

    assert {:ok, cres} = client_result
    assert {:ok, sres} = server_result

    # The responder always selects RC4, so the initiator negotiates encrypted mode.
    assert cres.mode == :rc4

    # The responder recovered the initiator's initial payload (its BT handshake).
    assert sres.leftover == ia

    # Cipher directions agree: client.send stream decrypts with server.recv.
    msg1 = "encrypted piece request and blocks"
    :ok = :gen_tcp.send(client, MSE.crypt(cres.send, msg1))
    {:ok, wire1} = :gen_tcp.recv(ssock, byte_size(msg1), @timeout)
    assert MSE.crypt(sres.recv, wire1) == msg1

    # ... and the reverse direction: server.send decrypts with client.recv.
    msg2 = "response bitfield and unchoke"
    :ok = :gen_tcp.send(ssock, MSE.crypt(sres.send, msg2))
    {:ok, wire2} = :gen_tcp.recv(client, byte_size(msg2), @timeout)
    assert MSE.crypt(cres.recv, wire2) == msg2

    send(server, :close)
    :gen_tcp.close(client)
  end

  test "responder rejects a torrent it does not serve" do
    info_hash = :crypto.strong_rand_bytes(20)
    ia = "payload"

    # Candidate list does NOT include info_hash → resolver returns nil.
    {client, client_result, {server_result, _ssock}, _server} =
      run_handshake(info_hash, ia, [:crypto.strong_rand_bytes(20)])

    assert {:error, :unknown_info_hash} = server_result
    # The initiator's handshake can't complete either (it never gets step 4).
    assert match?({:error, _}, client_result)

    :gen_tcp.close(client)
  end

  test "handshake works across a range of pad lengths (stress the sync scan)" do
    for _ <- 1..10 do
      info_hash = :crypto.strong_rand_bytes(20)
      ia = :crypto.strong_rand_bytes(68)

      {client, client_result, {server_result, _ssock}, server} =
        run_handshake(info_hash, ia, [info_hash])

      assert {:ok, _} = client_result
      assert {:ok, sres} = server_result
      assert sres.leftover == ia

      send(server, :close)
      :gen_tcp.close(client)
    end
  end
end

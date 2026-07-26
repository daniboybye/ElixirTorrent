defmodule PeerHashIntegrationTest do
  use ExUnit.Case, async: false

  alias Peer.HashWire

  @timeout 5_000
  @block Torrent.Merkle.block_size()

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)
    :ok
  end

  test "two loopback peers exchange hash_request and verified hashes" do
    blocks = for byte <- [?a, ?b, ?c, ?d], do: :binary.copy(<<byte>>, @block)
    {:ok, tree} = Torrent.Merkle.build(IO.iodata_to_binary(blocks))
    root = Torrent.Merkle.root(tree)
    {:ok, hashes} = Torrent.Merkle.range_response(tree, 0, 0, 2, 1)

    {client_a, server_a, listen_a, key_a, sender_a} = start_sender_pair()
    {client_b, server_b, listen_b, key_b, sender_b} = start_sender_pair()

    on_exit(fn ->
      cleanup(client_a, server_a, listen_a, sender_a, key_a)
      cleanup(client_b, server_b, listen_b, sender_b, key_b)
    end)

    req = %HashWire{
      pieces_root: root,
      base_layer: 0,
      index: 0,
      length: 2,
      proof_layers: 1
    }

    assert :ok = Peer.Sender.hash_request(key_a, req)

    assert {:ok, wire} = recv_framed(server_a, @timeout)
    assert <<21, body::binary>> = wire
    assert {:ok, decoded} = HashWire.decode_request(body)
    assert decoded == req

    assert :ok = Peer.Sender.hashes(key_b, req, IO.iodata_to_binary(hashes))

    assert {:ok, response} = recv_framed(server_b, @timeout)
    assert <<22, resp_body::binary>> = response
    assert {:ok, resp_req, digest_blob} = HashWire.decode_hashes(resp_body)
    assert resp_req == req
    assert {:ok, {base, proof}} = HashWire.split_hashes(req, digest_blob)
    assert base ++ proof == hashes
    assert Torrent.Merkle.verify_hashes(root, 0, 0, 2, 1, hashes, 4)
  end

  defp start_sender_pair do
    {client, server, listen} = loopback_sockets()

    hash = :crypto.strong_rand_bytes(20)
    id = :crypto.strong_rand_bytes(20)
    key = Peer.make_key(hash, id)

    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, client])
    assert :ok = Peer.Transport.controlling_process(client, sender_pid)
    assert :ok = Peer.Sender.activate(key)

    {client, server, listen, key, sender_pid}
  end

  defp loopback_sockets do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn(fn ->
      case :gen_tcp.accept(listen, @timeout) do
        {:ok, server} ->
          _ = :gen_tcp.controlling_process(server, parent)
          send(parent, {:loopback_server, server})

        error ->
          send(parent, {:loopback_accept_error, error})
      end
    end)

    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)

    receive do
      {:loopback_server, server} -> {client, server, listen}
      {:loopback_accept_error, error} -> flunk("accept failed: #{inspect(error)}")
    after
      @timeout -> flunk("accept timed out")
    end
  end

  defp recv_framed(server, timeout) do
    with {:ok, <<len::32>>} <- :gen_tcp.recv(server, 4, timeout) do
      :gen_tcp.recv(server, len, timeout)
    end
  end

  defp cleanup(client, server, listen, sender_pid, key) do
    _ = Peer.Sender.deactivate(key)

    for sock <- [client, server, listen] do
      try do
        if is_port(sock), do: :gen_tcp.close(sock)
      catch
        :error, _ -> :ok
      end
    end

    try do
      TestSupport.Sync.safe_stop(sender_pid, 500)
    catch
      :exit, _ -> :ok
    end
  end
end

defmodule Peer.TransportMSETest do
  use ExUnit.Case, async: true

  alias Peer.{MSE, Transport}

  # Two RC4 ciphers keyed identically per direction, as after a real handshake.
  defp cipher_pair do
    s = :crypto.strong_rand_bytes(96)
    skey = :crypto.strong_rand_bytes(20)
    a2b_key = MSE.key_a(s, skey)
    b2a_key = MSE.key_b(s, skey)

    a = %{send: MSE.new_cipher(a2b_key), recv: MSE.new_cipher(b2a_key)}
    b = %{send: MSE.new_cipher(b2a_key), recv: MSE.new_cipher(a2b_key)}
    {a, b}
  end

  test "wrap/raw/mse? expose the encryption layer" do
    {a, _b} = cipher_pair()
    sock = Transport.wrap(:fake_inner, a)

    assert Transport.mse?(sock)
    assert Transport.raw(sock) == :fake_inner
    refute Transport.mse?(:fake_inner)
    assert Transport.raw(:fake_inner) == :fake_inner
  end

  test "send encrypts and recv decrypts across a real loopback pair" do
    {a_ciphers, b_ciphers} = cipher_pair()

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, s} = :gen_tcp.accept(listen, 2_000)
      send(parent, {:server_sock, s})
      Process.sleep(2_000)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)
    server = receive do {:server_sock, s} -> s after 2_000 -> flunk("no accept") end

    a = Transport.wrap(client, a_ciphers)
    b = Transport.wrap(server, b_ciphers)

    # Ciphertext on the wire is not the plaintext.
    msg = "a peer wire message payload"
    :ok = Transport.send(a, msg)
    {:ok, on_wire} = :gen_tcp.recv(server, byte_size(msg), 2_000)
    refute on_wire == msg
    assert MSE.crypt(b_ciphers.recv, on_wire) == msg

    # And Transport.recv on a fresh cipher pair round-trips end to end.
    {a2, b2} = cipher_pair()
    a_sock = Transport.wrap(client, a2)
    b_sock = Transport.wrap(server, b2)
    reply = "bitfield then unchoke"
    :ok = Transport.send(b_sock, reply)
    assert {:ok, ^reply} = Transport.recv(a_sock, byte_size(reply), 2_000)

    :gen_tcp.close(client)
    :gen_tcp.close(listen)
  end
end

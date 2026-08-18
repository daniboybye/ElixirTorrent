defmodule Peer.MSEBackendTest do
  @moduledoc """
  Covers the seam that decides *which* RC4 this node uses, and both branches of
  `Peer.MSE.available?/0`.

  Before this seam existed the RC4-missing path could only be exercised on a
  host whose libcrypto had already dropped RC4 — i.e. everywhere except the
  machines the tests actually run on, which meant the tests asserted the
  opposite of the behaviour that was broken.
  """
  use ExUnit.Case, async: false

  alias Acceptor.Connection.Handshakes
  alias Peer.MSE
  alias Peer.MSE.{Handshake, RC4}

  @timeout 5_000

  setup do
    previous = Application.fetch_env(:elixir_torrent, :mse_rc4)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:elixir_torrent, :mse_rc4, value)
        :error -> Application.delete_env(:elixir_torrent, :mse_rc4)
      end
    end)

    :ok
  end

  defp set_backend(value), do: Application.put_env(:elixir_torrent, :mse_rc4, value)

  describe "backend/0" do
    test ":auto follows what libcrypto actually offers" do
      set_backend(:auto)

      expected = if :rc4 in :crypto.supports(:ciphers), do: :crypto, else: :pure
      assert MSE.backend() == expected
    end

    test "an unset key behaves like :auto" do
      Application.delete_env(:elixir_torrent, :mse_rc4)

      expected = if :rc4 in :crypto.supports(:ciphers), do: :crypto, else: :pure
      assert MSE.backend() == expected
    end

    test "an explicit value overrides the probe, and is re-read every call" do
      set_backend(:pure)
      assert MSE.backend() == :pure

      set_backend(:disabled)
      assert MSE.backend() == :disabled

      set_backend(:pure)
      assert MSE.backend() == :pure
    end
  end

  describe "available?/0" do
    test "is true for both working backends and false only when disabled" do
      set_backend(:pure)
      assert MSE.available?()

      set_backend(:auto)
      assert MSE.available?()

      set_backend(:disabled)
      refute MSE.available?()
    end
  end

  describe "new_cipher/1 across backends" do
    test "the pure backend produces a tagged handle, and still applies the discard" do
      key = :crypto.strong_rand_bytes(20)
      set_backend(:pure)

      assert {:pure, _state} = cipher = MSE.new_cipher(key)

      # MSE mandates dropping the first 1024 keystream bytes.
      raw = RC4.new(key)
      _ = RC4.crypt(raw, :binary.copy(<<0>>, 1_024))

      assert MSE.crypt(cipher, "after the discard") ==
               RC4.crypt(raw, "after the discard")
    end
  end

  # Forcing :crypto only makes sense where libcrypto still has RC4 — which is
  # exactly the host this fallback is not for.
  if :rc4 in :crypto.supports(:ciphers) do
    describe "cross-backend equivalence" do
      test "the two backends produce the same wire bytes" do
        # If this ever diverged, a Windows peer and a macOS peer could not talk.
        key = :crypto.strong_rand_bytes(20)
        payload = :crypto.strong_rand_bytes(3_000)

        set_backend(:pure)
        pure = MSE.crypt(MSE.new_cipher(key), payload)

        set_backend(:crypto)
        crypto = MSE.crypt(MSE.new_cipher(key), payload)

        assert pure == crypto
      end

      test "a stream encrypted by one backend decrypts with the other" do
        key = :crypto.strong_rand_bytes(20)
        payload = "piece 42, block 0"

        set_backend(:pure)
        sender = MSE.new_cipher(key)

        set_backend(:crypto)
        receiver = MSE.new_cipher(key)

        assert MSE.crypt(receiver, MSE.crypt(sender, payload)) == payload
      end
    end
  end

  describe "the full MSE handshake over the pure backend" do
    test "initiator and responder agree, and the data stream survives" do
      set_backend(:pure)

      info_hash = :crypto.strong_rand_bytes(20)
      ia = "\x13BitTorrent protocol" <> :crypto.strong_rand_bytes(48)

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      parent = self()
      close_gate = make_ref()

      responder =
        spawn_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, @timeout)
          result = Handshake.respond(sock, Handshake.resolver([info_hash]), @timeout)
          send(parent, {:responded, result, sock})

          receive do
            ^close_gate -> :gen_tcp.close(sock)
          end
        end)

      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)

      assert {:ok, %{mode: :rc4} = initiator} =
               Handshake.initiate(client, info_hash, ia, @timeout)

      assert_receive {:responded, {:ok, responder_res}, server_sock}, @timeout

      # The responder recovered our initial payload out of the encrypted stream.
      assert responder_res.leftover == ia

      # Both ciphers are the pure ones, and both directions decode.
      assert {:pure, _} = initiator.send
      assert {:pure, _} = responder_res.recv

      out = "encrypted request for piece 7"
      :ok = :gen_tcp.send(client, MSE.crypt(initiator.send, out))
      assert {:ok, wire} = :gen_tcp.recv(server_sock, byte_size(out), @timeout)
      assert MSE.crypt(responder_res.recv, wire) == out

      back = "unchoke, then the block"
      :ok = :gen_tcp.send(server_sock, MSE.crypt(responder_res.send, back))
      assert {:ok, wire_back} = :gen_tcp.recv(client, byte_size(back), @timeout)
      assert MSE.crypt(initiator.recv, wire_back) == back

      send(responder, close_gate)
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end
  end

  describe "the disabled branch, which used to be unreachable in tests" do
    setup do
      {:ok, _} = Application.ensure_all_started(:elixir_torrent)
      :ok
    end

    test "an inbound MSE connection is dropped rather than answered" do
      set_backend(:disabled)

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      parent = self()

      acceptor =
        Task.async(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, @timeout)
          send(parent, {:accepted, self()})
          Handshakes.recv(sock)
        end)

      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)
      assert_receive {:accepted, _}, @timeout

      # First byte of an MSE `Ya`: anything that is not the plaintext pstrlen 19.
      # (A real Ya is 96 random bytes; the sniff only looks at the first one.)
      :ok = :gen_tcp.send(client, <<0x2A>>)

      assert :ok = Task.await(acceptor, @timeout)
      assert {:error, :closed} = :gen_tcp.recv(client, 0, @timeout)

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end
  end
end

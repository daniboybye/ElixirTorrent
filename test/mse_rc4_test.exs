defmodule Peer.MSE.RC4Test do
  use ExUnit.Case, async: true

  alias Peer.MSE.RC4

  # RFC 6229 §2 test vectors. RC4's keystream is what it XORs with, so encrypting
  # zero bytes yields the keystream itself. These pin the implementation to the
  # algorithm rather than to whatever `:crypto` happens to do on this host, which
  # is the whole point: on the machine this fallback exists for, `:crypto` has no
  # RC4 to compare against.
  @rfc6229 [
    {<<0x01, 0x02, 0x03, 0x04, 0x05>>, "B2396305F03DC027CCC3524A0A1118A8"},
    {<<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08>>, "97AB8A1BF0AFB96132F2F67258DA15A8"},
    {<<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
       0x10>>, "9AC7CC9A609D1EF7B2932899CDE41B97"}
  ]

  describe "algorithm correctness" do
    test "matches the RFC 6229 keystream vectors" do
      for {key, hex} <- @rfc6229 do
        expected = Base.decode16!(hex)
        keystream = RC4.crypt(RC4.new(key), :binary.copy(<<0>>, byte_size(expected)))
        assert keystream == expected, "keystream mismatch for key #{inspect(key)}"
      end
    end

    test "is symmetric: two ciphers on the same key round-trip a message" do
      key = :crypto.strong_rand_bytes(20)
      plaintext = :crypto.strong_rand_bytes(4_096)

      ciphertext = RC4.crypt(RC4.new(key), plaintext)

      refute ciphertext == plaintext
      assert RC4.crypt(RC4.new(key), ciphertext) == plaintext
    end

    test "is a stream: chunk boundaries do not change the output" do
      key = :crypto.strong_rand_bytes(20)
      whole = RC4.crypt(RC4.new(key), "helloworld and then some more bytes")

      cipher = RC4.new(key)

      chunked =
        Enum.map_join(["hello", "world and ", "then some more bytes"], fn chunk ->
          RC4.crypt(cipher, chunk)
        end)

      assert chunked == whole
    end

    test "accepts iodata like :crypto.crypto_update/2 does" do
      key = :crypto.strong_rand_bytes(20)

      assert RC4.crypt(RC4.new(key), ["he", ["ll", "o"]]) == RC4.crypt(RC4.new(key), "hello")
    end

    test "encrypting nothing advances nothing" do
      key = :crypto.strong_rand_bytes(20)
      cipher = RC4.new(key)

      assert RC4.crypt(cipher, "") == ""
      assert RC4.crypt(cipher, "abc") == RC4.crypt(RC4.new(key), "abc")
    end

    test "keys of different lengths give different streams" do
      probe = fn key -> RC4.crypt(RC4.new(key), :binary.copy(<<0>>, 32)) end

      refute probe.(<<1, 2, 3>>) == probe.(<<1, 2, 3, 4>>)
    end
  end

  describe "discard/2" do
    test "skipping n bytes lands on the same position as encrypting n bytes" do
      key = :crypto.strong_rand_bytes(20)

      skipped = RC4.new(key)
      :ok = RC4.discard(skipped, 1_024)

      consumed = RC4.new(key)
      _ = RC4.crypt(consumed, :binary.copy(<<0>>, 1_024))

      assert RC4.crypt(skipped, "payload") == RC4.crypt(consumed, "payload")
    end

    test "discarding zero bytes is a no-op" do
      key = :crypto.strong_rand_bytes(20)
      cipher = RC4.new(key)
      :ok = RC4.discard(cipher, 0)

      assert RC4.crypt(cipher, "abc") == RC4.crypt(RC4.new(key), "abc")
    end
  end

  describe "state handling" do
    test "the cipher handle is mutable, so callers need not rebind it" do
      key = :crypto.strong_rand_bytes(20)
      cipher = RC4.new(key)

      first = RC4.crypt(cipher, "aaaa")
      second = RC4.crypt(cipher, "aaaa")

      refute first == second
    end

    test "the handle survives being sent to another process" do
      # This is why the state lives in :atomics rather than the process
      # dictionary: the MSE handshake builds the ciphers in a task and hands
      # them to Peer.Sender.
      key = :crypto.strong_rand_bytes(20)
      cipher = RC4.new(key)
      parent = self()

      {pid, monitor} =
        spawn_monitor(fn -> send(parent, {:out, RC4.crypt(cipher, "hello")}) end)

      assert_receive {:out, remote}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000

      assert remote == RC4.crypt(RC4.new(key), "hello")

      # ...and the shared handle advanced there, so the parent continues the
      # same stream rather than restarting it.
      whole = RC4.crypt(RC4.new(key), "helloworld")
      assert RC4.crypt(cipher, "world") == binary_part(whole, 5, 5)
    end
  end

  if :rc4 in :crypto.supports(:ciphers) do
    describe "parity with :crypto (hosts whose libcrypto still exposes RC4)" do
      test "produces identical output over randomised keys and sizes" do
        for _ <- 1..100 do
          key = :crypto.strong_rand_bytes(Enum.random(1..40))
          data = :crypto.strong_rand_bytes(Enum.random(0..3_000))

          reference = :crypto.crypto_update(:crypto.crypto_init(:rc4, key, true), data)

          assert RC4.crypt(RC4.new(key), data) == reference
        end
      end
    end
  end
end

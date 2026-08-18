defmodule Peer.MSETest do
  use ExUnit.Case, async: true

  alias Peer.MSE
  alias Peer.MSE.RC4

  describe "Diffie-Hellman key agreement" do
    test "both sides derive the same 96-byte shared secret" do
      a = MSE.generate_keypair()
      b = MSE.generate_keypair()

      assert byte_size(a.public) == 96
      assert byte_size(b.public) == 96

      s_a = MSE.shared_secret(b.public, a.private)
      s_b = MSE.shared_secret(a.public, b.private)

      assert s_a == s_b
      assert byte_size(s_a) == 96
    end

    test "distinct keypairs produce distinct secrets" do
      a = MSE.generate_keypair()
      b = MSE.generate_keypair()
      c = MSE.generate_keypair()

      refute MSE.shared_secret(b.public, a.private) == MSE.shared_secret(c.public, a.private)
    end
  end

  describe "key / obfuscation derivations" do
    setup do
      s = :crypto.strong_rand_bytes(96)
      skey = :crypto.strong_rand_bytes(20)
      %{s: s, skey: skey}
    end

    test "req1 is SHA1('req1' <> S)", %{s: s} do
      assert MSE.req1(s) == :crypto.hash(:sha, "req1" <> s)
      assert byte_size(MSE.req1(s)) == 20
    end

    test "req2_req3 is HASH('req2',SKEY) xor HASH('req3',S)", %{s: s, skey: skey} do
      expected =
        :crypto.exor(
          :crypto.hash(:sha, "req2" <> skey),
          :crypto.hash(:sha, "req3" <> s)
        )

      assert MSE.req2_req3(s, skey) == expected
    end

    test "keyA and keyB differ and are 20 bytes", %{s: s, skey: skey} do
      assert byte_size(MSE.key_a(s, skey)) == 20
      assert byte_size(MSE.key_b(s, skey)) == 20
      refute MSE.key_a(s, skey) == MSE.key_b(s, skey)
    end
  end

  describe "RC4 stream cipher with 1024-byte discard" do
    test "a fresh cipher skips the first 1024 keystream bytes" do
      key = :crypto.strong_rand_bytes(20)

      mse = MSE.crypt(MSE.new_cipher(key), <<0::800>>)

      # Reference keystream from an undiscarded cipher. Not `:crypto` directly:
      # libcrypto has no RC4 on an OpenSSL 3 build without the legacy provider
      # (Windows), and hardcoding it here made this test fail on the very
      # platform the built-in implementation exists for.
      raw_ref = RC4.new(key)
      raw = RC4.crypt(raw_ref, :binary.copy(<<0>>, 1024 + 100))
      raw_after_discard = binary_part(raw, 1024, 100)

      assert binary_part(mse, 0, 100) == raw_after_discard
    end

    test "initiator encrypt / receiver decrypt round-trips over the keyA stream" do
      s = :crypto.strong_rand_bytes(96)
      skey = :crypto.strong_rand_bytes(20)

      enc = MSE.new_cipher(MSE.key_a(s, skey))
      dec = MSE.new_cipher(MSE.key_a(s, skey))

      plaintext = "BitTorrent protocol handshake and beyond"
      cipher = MSE.crypt(enc, plaintext)

      refute cipher == plaintext
      assert MSE.crypt(dec, cipher) == plaintext
    end

    test "streaming in chunks matches encrypting all at once" do
      key = MSE.key_b(:crypto.strong_rand_bytes(96), :crypto.strong_rand_bytes(20))

      chunked =
        (fn c -> MSE.crypt(c, "hello") <> MSE.crypt(c, "world") end).(MSE.new_cipher(key))

      whole = MSE.crypt(MSE.new_cipher(key), "helloworld")

      assert chunked == whole
    end
  end

  describe "constants" do
    test "vc is 8 zero bytes and prime is 96 bytes" do
      assert MSE.vc() == <<0, 0, 0, 0, 0, 0, 0, 0>>
      assert byte_size(MSE.prime()) == 96
      assert MSE.crypto_plaintext() == 0x01
      assert MSE.crypto_rc4() == 0x02
    end
  end

  describe "available?/0" do
    test "MSE is available out of the box, whatever libcrypto offers" do
      # This is the behaviour change: it used to answer
      # `:rc4 in :crypto.supports(:ciphers)`, so a host without libcrypto RC4
      # fell back to plaintext-only peering. Peer.MSE.RC4 removes that
      # dependency, so the default answer is now unconditionally true.
      assert MSE.available?()
    end

    test "is stable across calls" do
      assert MSE.available?() == MSE.available?()
    end

    test "new_cipher/1 works regardless of what libcrypto offers" do
      # The old contract was "available?/0 is true exactly when new_cipher/1
      # does not raise". There is no longer a raising branch to pair with.
      assert MSE.crypt(MSE.new_cipher(:binary.copy(<<1>>, 20)), "abc") != "abc"
    end
  end
end

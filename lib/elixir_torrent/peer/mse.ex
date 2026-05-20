defmodule Peer.MSE do
  @moduledoc """
  Message Stream Encryption / Protocol Encryption (MSE/PE) crypto core.

  MSE obfuscates the BitTorrent stream to resist ISP throttling and to interop
  with encryption-only peers. It is not a strong security layer — it uses a
  fixed 768-bit MODP Diffie-Hellman group and RC4 — but that is exactly the
  wire protocol other clients speak, so we match it.

  This module is the primitives layer only (no socket I/O): DH key agreement,
  the SHA1-based key/obfuscation derivations, and the RC4 stream cipher with the
  mandatory 1024-byte keystream discard. The handshake state machine that drives
  these over a connection lives separately.

  Reference: <https://wiki.vuze.com/w/Message_Stream_Encryption>.
  """

  # Well-known MSE Diffie-Hellman parameters: the 768-bit MODP group, generator 2.
  @p String.to_integer(
       "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A3621" <>
         "000000000090563",
       16
     )
  @g 2
  @key_len 96
  @rc4_discard 1024

  # Verification constant (8 zero bytes) — lets the receiver confirm it derived
  # the right key: the first decrypted bytes after the hashes must equal this.
  @vc <<0::64>>

  # crypto_provide / crypto_select bit flags.
  @crypto_plaintext 0x01
  @crypto_rc4 0x02

  @type keypair :: %{private: binary(), public: binary()}
  @type cipher :: :crypto.crypto_state()

  @doc "The verification constant (8 zero bytes)."
  @spec vc() :: binary()
  def vc, do: @vc

  @doc false
  @spec crypto_plaintext() :: 1
  def crypto_plaintext, do: @crypto_plaintext
  @doc false
  @spec crypto_rc4() :: 2
  def crypto_rc4, do: @crypto_rc4
  @doc false
  @spec key_len() :: 96
  def key_len, do: @key_len

  @doc """
  Generate an ephemeral DH keypair. `public` (`Ya`/`Yb`) is the 96-byte value
  put on the wire; `private` (`Xa`/`Xb`) stays local.
  """
  @spec generate_keypair() :: keypair()
  def generate_keypair do
    private = :crypto.strong_rand_bytes(20)
    public = :crypto.mod_pow(<<@g>>, private, prime()) |> pad_left(@key_len)
    %{private: private, public: public}
  end

  @doc """
  Compute the 96-byte shared secret `S` from the peer's public key and our
  private key.
  """
  @spec shared_secret(binary(), binary()) :: binary()
  def shared_secret(peer_public, private)
      when is_binary(peer_public) and is_binary(private) do
    :crypto.mod_pow(peer_public, private, prime()) |> pad_left(@key_len)
  end

  @doc "`SHA1(prefix <> rest...)` — the MSE hash primitive."
  @spec hash(binary(), [binary()]) :: binary()
  def hash(prefix, parts) when is_binary(prefix) and is_list(parts) do
    :crypto.hash(:sha, [prefix | parts])
  end

  @doc "`HASH('req1', S)` — sent in clear so the receiver can sync on it."
  @spec req1(binary()) :: binary()
  def req1(s), do: hash("req1", [s])

  @doc """
  `HASH('req2', SKEY) xor HASH('req3', S)` — obfuscates the info hash so only a
  peer that already knows both `S` and the torrent can recognise it.
  """
  @spec req2_req3(binary(), binary()) :: binary()
  def req2_req3(s, skey) do
    xor(hash("req2", [skey]), hash("req3", [s]))
  end

  @doc "RC4 key for the initiator→receiver direction: `HASH('keyA', S, SKEY)`."
  @spec key_a(binary(), binary()) :: binary()
  def key_a(s, skey), do: hash("keyA", [s, skey])

  @doc "RC4 key for the receiver→initiator direction: `HASH('keyB', S, SKEY)`."
  @spec key_b(binary(), binary()) :: binary()
  def key_b(s, skey), do: hash("keyB", [s, skey])

  @doc """
  Build an RC4 stream cipher from a derived key, discarding the first
  #{@rc4_discard} bytes of keystream as MSE requires. The returned reference is
  stateful — feed it the whole stream in order.
  """
  @spec new_cipher(binary()) :: cipher()
  def new_cipher(key) when is_binary(key) do
    ref = :crypto.crypto_init(:rc4, key, true)
    _ = :crypto.crypto_update(ref, :binary.copy(<<0>>, @rc4_discard))
    ref
  end

  @doc "Encrypt/decrypt `data` through the (symmetric) RC4 stream `cipher`."
  @spec crypt(cipher(), iodata()) :: binary()
  def crypt(cipher, data), do: :crypto.crypto_update(cipher, data)

  @doc "XOR two equal-length binaries."
  @spec xor(binary(), binary()) :: binary()
  def xor(a, b) when byte_size(a) == byte_size(b) do
    :crypto.exor(a, b)
  end

  @doc "The MSE prime `P` as a 96-byte big-endian binary."
  @spec prime() :: binary()
  def prime, do: :binary.encode_unsigned(@p)

  @spec pad_left(binary(), non_neg_integer()) :: binary()
  defp pad_left(bin, size) when byte_size(bin) >= size, do: bin
  defp pad_left(bin, size), do: :binary.copy(<<0>>, size - byte_size(bin)) <> bin
end

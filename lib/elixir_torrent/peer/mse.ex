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

  RC4 comes either from `:crypto` or, where libcrypto refuses to provide it
  (OpenSSL 3 keeps RC4 in an optional `legacy` provider that the Windows ERTS
  build has no module for), from `Peer.MSE.RC4`. See `backend/0`; the choice is
  invisible to callers.

  Reference: <https://wiki.vuze.com/w/Message_Stream_Encryption>.
  """

  alias Peer.MSE.RC4

  require Logger

  # Well-known MSE Diffie-Hellman parameters: the 768-bit MODP group, generator 2.
  @p String.to_integer(
       "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A3621" <>
         "000000000090563",
       16
     )
  @g 2
  @key_len 96
  @rc4_discard 1024

  # Memoisation slot for the libcrypto RC4 probe.
  @availability_key {__MODULE__, :rc4_available}

  # Verification constant (8 zero bytes) — lets the receiver confirm it derived
  # the right key: the first decrypted bytes after the hashes must equal this.
  @vc <<0::64>>

  # crypto_provide / crypto_select bit flags.
  @crypto_plaintext 0x01
  @crypto_rc4 0x02

  @type keypair :: %{private: binary(), public: binary()}
  @type cipher :: :crypto.crypto_state() | {:pure, RC4.t()}
  @type backend :: :crypto | :pure | :disabled

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
  Which RC4 implementation this node will use: `:crypto`, `:pure`, or
  `:disabled`.

  Resolved from `config :elixir_torrent, :mse_rc4`, which accepts:

    * `:auto` (default) — `:crypto` when the linked libcrypto exposes RC4,
      otherwise `:pure`;
    * `:crypto` / `:pure` — force one implementation. Forcing `:pure` on a host
      that has `:crypto` RC4 is how the fallback gets exercised in tests;
    * `:disabled` — refuse MSE entirely and speak only plaintext.

  The libcrypto probe is memoised (it cannot change while the VM is up); the
  configured override is read each time, so it stays injectable.
  """
  @spec backend() :: backend()
  def backend do
    case Application.get_env(:elixir_torrent, :mse_rc4, :auto) do
      :auto -> if crypto_has_rc4?(), do: :crypto, else: :pure
      other when other in [:crypto, :pure, :disabled] -> other
    end
  end

  @doc """
  Whether this node will speak MSE at all.

  Every MSE handshake is itself RC4-encrypted — even the exchange that ends up
  selecting a *plaintext* data stream — so a node without RC4 cannot use the
  scheme at all and must dial in the clear instead. Since `Peer.MSE.RC4` gives
  us RC4 unconditionally, this is now false only when MSE is explicitly
  disabled by configuration.
  """
  @spec available?() :: boolean()
  def available?, do: backend() != :disabled

  # OpenSSL 3 moved RC4 into the optional `legacy` provider. OTP's crypto NIF
  # does try `OSSL_PROVIDER_load(NULL, "legacy")`, but tolerates the load
  # failing, so on a build whose libcrypto ships no legacy module (the Windows
  # ERTS, measured against OpenSSL 3.5.5) `:crypto.supports(:ciphers)` omits
  # `:rc4` and `crypto_init/3` raises `:notsup`. Same OpenSSL version on macOS
  # via Homebrew does have the module and does list `:rc4` — so this is a
  # property of the individual build, not of the version.
  @spec crypto_has_rc4?() :: boolean()
  defp crypto_has_rc4? do
    case :persistent_term.get(@availability_key, :unknown) do
      :unknown ->
        supported = :rc4 in :crypto.supports(:ciphers)

        unless supported do
          Logger.debug(
            "MSE: libcrypto has no RC4 (OpenSSL 3 legacy provider unavailable); " <>
              "using the built-in RC4 implementation"
          )
        end

        :persistent_term.put(@availability_key, supported)
        supported

      cached ->
        cached
    end
  end

  @doc """
  Build an RC4 stream cipher from a derived key, discarding the first
  #{@rc4_discard} bytes of keystream as MSE requires. The returned value is a
  stateful handle whose position advances in place — feed it the whole stream in
  order, from one process at a time.

  Uses whichever implementation `backend/0` selects; the two are
  interchangeable, so a cipher built on one node decrypts a stream produced by
  the other.
  """
  @spec new_cipher(binary()) :: cipher()
  def new_cipher(key) when is_binary(key) do
    case backend() do
      :crypto ->
        ref = :crypto.crypto_init(:rc4, key, true)
        _ = :crypto.crypto_update(ref, :binary.copy(<<0>>, @rc4_discard))
        ref

      # `:disabled` is enforced where connections are decided (see
      # `Acceptor.Connection.Handshakes`), not here: a cipher asked for anyway
      # should work rather than raise from inside a handshake.
      _pure_or_disabled ->
        state = RC4.new(key)
        :ok = RC4.discard(state, @rc4_discard)
        {:pure, state}
    end
  end

  @doc "Encrypt/decrypt `data` through the (symmetric) RC4 stream `cipher`."
  @spec crypt(cipher(), iodata()) :: binary()
  def crypt({:pure, state}, data), do: RC4.crypt(state, data)
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

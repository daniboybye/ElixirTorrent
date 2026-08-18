defmodule Peer.MSE.RC4 do
  @moduledoc """
  A self-contained RC4 stream cipher, used when the VM's crypto backend refuses
  to provide one.

  ## Why this exists

  MSE/PE is specified over RC4 (Vuze MSE spec), and the *whole* handshake — not
  just the data stream — is RC4-encrypted. A client without RC4 therefore cannot
  speak MSE at all, not even to negotiate a plaintext stream. Meanwhile OpenSSL 3
  moved RC4 into the optional `legacy` provider: OTP's crypto NIF tries
  `OSSL_PROVIDER_load(NULL, "legacy")` and deliberately tolerates failure, so on a
  build whose libcrypto ships no legacy module (the Windows ERTS) `:crypto` simply
  omits `:rc4` and `:crypto.crypto_init(:rc4, ...)` raises `:notsup`.

  Every other BitTorrent implementation solved this the same way — by carrying its
  own RC4 rather than depending on a crypto library's deprecation policy:
  libtorrent (`src/pe_crypto.cpp`, from libTomCrypt), Transmission
  (`libtransmission/tr-arc4.h`), Vuze (a bundled `org.gudy.bouncycastle`
  `RC4Engine`), and WebTorrent's `bittorrent-protocol` (a JS fallback behind a
  `nativeRC4` probe). This module is the same decision.

  ## Representation

  The state lives in an `:atomics` array, which is a *mutable* reference: that
  preserves `Peer.MSE.crypt/2`'s existing contract (the cipher is a handle whose
  position advances in place) so callers keep working unchanged, and it lets the
  cipher be handed from the handshake process to `Peer.Sender` like the `:crypto`
  reference it replaces. Slots 1..256 hold the S-box; 257 and 258 hold the stream
  position `i`/`j`.

  A cipher is a single stream and must be driven by one process at a time, in
  order — exactly the same rule as `:crypto.crypto_update/2`.
  """

  import Bitwise

  # S-box occupies 1..256; the two stream counters live just past it.
  @sbox 256
  @i_slot 257
  @j_slot 258

  @type t :: :atomics.atomics_ref()

  @doc """
  Run the RC4 key-scheduling algorithm for `key` and return a fresh stream.
  """
  @spec new(binary()) :: t()
  def new(key) when is_binary(key) and byte_size(key) > 0 do
    state = :atomics.new(@sbox + 2, signed: false)
    for x <- 0..255, do: :atomics.put(state, x + 1, x)

    key_len = byte_size(key)

    _final_j =
      Enum.reduce(0..255, 0, fn x, j ->
        sx = :atomics.get(state, x + 1)
        j = j + sx + :binary.at(key, rem(x, key_len)) &&& 255
        :atomics.put(state, x + 1, :atomics.get(state, j + 1))
        :atomics.put(state, j + 1, sx)
        j
      end)

    state
  end

  @doc """
  Advance the stream by `n` keystream bytes without producing output.

  MSE requires the first 1024 bytes of each direction's keystream to be thrown
  away (they leak the most about the key).
  """
  @spec discard(t(), non_neg_integer()) :: :ok
  def discard(state, n) when is_integer(n) and n >= 0 do
    {i, j} = skip(state, n, :atomics.get(state, @i_slot), :atomics.get(state, @j_slot))
    :atomics.put(state, @i_slot, i)
    :atomics.put(state, @j_slot, j)
    :ok
  end

  @doc """
  XOR `data` with the next bytes of the keystream, advancing the stream.

  RC4 is symmetric, so this both encrypts and decrypts.
  """
  @spec crypt(t(), iodata()) :: binary()
  def crypt(state, data) do
    bin = IO.iodata_to_binary(data)

    {out, i, j} =
      run(state, :atomics.get(state, @i_slot), :atomics.get(state, @j_slot), bin, <<>>)

    :atomics.put(state, @i_slot, i)
    :atomics.put(state, @j_slot, j)
    out
  end

  # Eight bytes per clause: the per-clause call and binary-append overhead is a
  # meaningful share of the cost when the body is this small (measured ~42 -> ~52
  # MiB/s on an M-series mac).
  @spec run(t(), 0..255, 0..255, binary(), binary()) :: {binary(), 0..255, 0..255}
  defp run(state, i, j, <<a1, a2, a3, a4, a5, a6, a7, a8, rest::binary>>, acc) do
    {k1, i, j} = step(state, i, j)
    {k2, i, j} = step(state, i, j)
    {k3, i, j} = step(state, i, j)
    {k4, i, j} = step(state, i, j)
    {k5, i, j} = step(state, i, j)
    {k6, i, j} = step(state, i, j)
    {k7, i, j} = step(state, i, j)
    {k8, i, j} = step(state, i, j)

    acc =
      <<acc::binary, bxor(a1, k1), bxor(a2, k2), bxor(a3, k3), bxor(a4, k4), bxor(a5, k5),
        bxor(a6, k6), bxor(a7, k7), bxor(a8, k8)>>

    run(state, i, j, rest, acc)
  end

  defp run(state, i, j, <<byte, rest::binary>>, acc) do
    {k, i, j} = step(state, i, j)
    run(state, i, j, rest, <<acc::binary, bxor(byte, k)>>)
  end

  defp run(_state, i, j, <<>>, acc), do: {acc, i, j}

  @spec skip(t(), non_neg_integer(), 0..255, 0..255) :: {0..255, 0..255}
  defp skip(_state, 0, i, j), do: {i, j}

  defp skip(state, n, i, j) do
    {_k, i, j} = step(state, i, j)
    skip(state, n - 1, i, j)
  end

  # One PRGA round. `:atomics.exchange/3` writes S[j] and reads its old value in a
  # single call, which is why the swap costs four array operations rather than five.
  @compile {:inline, step: 3}
  @spec step(t(), 0..255, 0..255) :: {0..255, 0..255, 0..255}
  defp step(state, i, j) do
    i = i + 1 &&& 255
    si = :atomics.get(state, i + 1)
    j = j + si &&& 255
    sj = :atomics.exchange(state, j + 1, si)
    :atomics.put(state, i + 1, sj)
    {:atomics.get(state, (si + sj &&& 255) + 1), i, j}
  end
end

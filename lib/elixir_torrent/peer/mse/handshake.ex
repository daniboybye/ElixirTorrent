defmodule Peer.MSE.Handshake do
  @moduledoc """
  MSE/PE handshake state machine (BEP-adjacent; Vuze Message Stream Encryption).

  Runs the encrypted handshake over a passive `Peer.Transport` socket, before the
  BitTorrent handshake. Two roles:

    * `initiate/3` — the dialer (A). Sends `Ya + PadA`, reads `Yb`, sends the
      encrypted request (obfuscated info hash + `VC/crypto_provide/IA`), reads the
      peer's `crypto_select`.
    * `respond/2` — the accepter (B). Reads `Ya`, recovers the torrent from the
      obfuscated info hash, replies with `Yb + PadB` and the encrypted
      `VC/crypto_select`, and hands back the peer's initial BT handshake (`IA`).

  The hard part is resynchronising after the variable 0–512 byte pads: the reader
  scans the raw stream for a known marker (the cleartext `HASH('req1',S)` for B,
  the encrypted `VC` for A) and treats everything before it as padding.

  Both sides return `{:ok, %{recv: cipher, send: cipher, leftover: binary}}` — the
  two directional RC4 ciphers plus any already-received plaintext payload — or
  `{:error, reason}`. RC4 is negotiated; plaintext-select is honoured too.
  """

  import Bitwise, only: [|||: 2]

  alias Peer.{MSE, Transport}

  @max_pad 512
  # Bound the pre-sync scan so a hostile or mismatched peer can't make us read forever.
  @max_scan @max_pad + 40
  @vc MSE.vc()

  # `respond` always returns rc4 ciphers. `initiate` tags the negotiated `:mode`
  # and, when the peer selected plaintext, omits the ciphers (stream is cleartext).
  @type result ::
          %{mode: :rc4, recv: MSE.cipher(), send: MSE.cipher(), leftover: binary()}
          | %{mode: :plaintext, leftover: binary()}
          | %{recv: MSE.cipher(), send: MSE.cipher(), leftover: binary()}

  # ---- Initiator (dialer, "A") ------------------------------------------------

  @doc """
  Perform the MSE handshake as the initiator. `ia` is the plaintext to send
  encrypted as the "initial payload" (our BitTorrent handshake). Returns the
  negotiated ciphers; the caller keeps using `send`/`recv` for the rest of the
  stream (already positioned past the handshake).
  """
  @spec initiate(Transport.socket(), Torrent.hash(), binary(), timeout()) ::
          {:ok, result()} | {:error, term()}
  def initiate(socket, info_hash, ia, timeout \\ 15_000) do
    keys = MSE.generate_keypair()

    with :ok <- Transport.send(socket, [keys.public, pad()]),
         {:ok, yb} <- recv_exact(socket, MSE.key_len(), timeout) do
      s = MSE.shared_secret(yb, keys.private)
      send_cipher = MSE.new_cipher(MSE.key_a(s, info_hash))
      recv_cipher = MSE.new_cipher(MSE.key_b(s, info_hash))

      req = build_initiator_request(s, info_hash, send_cipher, ia)

      with :ok <- Transport.send(socket, req),
           {:ok, crypto_select, leftover} <- read_select(socket, recv_cipher, timeout) do
        interpret_select(crypto_select, recv_cipher, send_cipher, leftover)
      end
    end
  end

  # B picks ONE method from the `crypto_provide` we offered (plaintext|rc4). We
  # MUST honour its choice for the post-handshake data stream:
  #
  #   * rc4       -> keep the two RC4 ciphers; the rest of the stream is encrypted.
  #   * plaintext -> the data stream is cleartext, so the caller uses the RAW
  #                  socket. (Our IA was still sent RC4-encrypted in step 3 — that
  #                  is correct; crypto_select only governs the stream AFTER the
  #                  handshake.) Ignoring this was the outbound `:invalid_handshake`
  #                  bug: we kept RC4-decrypting a peer that had gone plaintext.
  #
  # Anything else is a protocol violation (B must echo one of our offered bits).
  @spec interpret_select(non_neg_integer(), MSE.cipher(), MSE.cipher(), binary()) ::
          {:ok, result()} | {:error, term()}
  defp interpret_select(select, recv_cipher, send_cipher, leftover) do
    cond do
      select == MSE.crypto_rc4() ->
        {:ok, %{mode: :rc4, recv: recv_cipher, send: send_cipher, leftover: leftover}}

      select == MSE.crypto_plaintext() ->
        {:ok, %{mode: :plaintext, leftover: leftover}}

      true ->
        {:error, {:mse_bad_select, select}}
    end
  end

  # A -> B step 3: HASH('req1',S), HASH('req2',SKEY) xor HASH('req3',S),
  # ENCRYPT(VC, crypto_provide, len(PadC)=0, len(IA), IA).
  defp build_initiator_request(s, info_hash, cipher, ia) do
    provide = <<0::24, MSE.crypto_plaintext() ||| MSE.crypto_rc4()>>
    ia = IO.iodata_to_binary(ia)
    plain = <<@vc::binary, provide::binary, 0::16, byte_size(ia)::16, ia::binary>>

    [MSE.req1(s), MSE.req2_req3(s, info_hash), MSE.crypt(cipher, plain)]
  end

  # Read B's ENCRYPT(VC, crypto_select, len(PadD), PadD). Sync on the encrypted VC:
  # generating it advances the cipher past those 8 bytes, so decryption of the
  # following crypto_select/PadD continues seamlessly.
  defp read_select(socket, cipher, timeout) do
    evc = MSE.crypt(cipher, @vc)

    with :ok <- scan_for(socket, evc, timeout),
         {:ok, enc_rest} <- recv_exact(socket, 6, timeout) do
      <<select::32, pad_len::16>> = MSE.crypt(cipher, enc_rest)

      # Consume and decrypt PadD so the cipher is positioned for the data stream.
      with {:ok, _padd} <- recv_exact_maybe_decrypt(socket, cipher, pad_len, timeout) do
        {:ok, select, <<>>}
      end
    end
  end

  # ---- Responder (accepter, "B") ----------------------------------------------

  @doc """
  Perform the MSE handshake as the responder. `resolve` maps the obfuscated info
  hash to a known torrent hash (or `nil` if we don't serve it). Returns the
  ciphers plus `leftover` = the peer's decrypted initial BT handshake (`IA`).
  """
  @spec respond(
          Transport.socket(),
          (binary(), binary() -> Torrent.hash() | nil),
          timeout(),
          binary()
        ) ::
          {:ok, result()} | {:error, term()}
  def respond(socket, resolve, timeout \\ 15_000, prefix \\ <<>>) do
    keys = MSE.generate_keypair()

    # `prefix` is any bytes of Ya already consumed while sniffing plaintext-vs-MSE.
    # Step 2 (Yb + PadB) must go out before we block reading step 3, otherwise
    # both sides wait for each other (the initiator holds step 3 until it has Yb).
    with {:ok, ya} <- recv_initiator_public_key(socket, prefix, timeout),
         :ok <- Transport.send(socket, [keys.public, pad()]) do
      respond_after_yb(socket, keys, ya, resolve, timeout)
    end
  end

  @spec recv_initiator_public_key(Transport.socket(), binary(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  defp recv_initiator_public_key(socket, prefix, timeout) do
    with {:ok, rest} <- recv_exact(socket, MSE.key_len() - byte_size(prefix), timeout) do
      {:ok, prefix <> rest}
    end
  end

  @spec respond_after_yb(
          Transport.socket(),
          term(),
          binary(),
          (binary(), binary() -> Torrent.hash() | nil),
          timeout()
        ) :: {:ok, result()} | {:error, term()}
  defp respond_after_yb(socket, keys, ya, resolve, timeout) do
    s = MSE.shared_secret(ya, keys.private)

    # Sync on the cleartext HASH('req1', S), skipping PadA.
    with :ok <- scan_for(socket, MSE.req1(s), timeout),
         {:ok, req2_3} <- recv_exact(socket, 20, timeout),
         info_hash when is_binary(info_hash) <- resolve.(s, req2_3) do
      finish_respond(socket, s, info_hash, timeout)
    else
      nil -> {:error, :unknown_info_hash}
      {:error, _} = error -> error
    end
  end

  defp finish_respond(socket, s, info_hash, timeout) do
    recv_cipher = MSE.new_cipher(MSE.key_a(s, info_hash))
    send_cipher = MSE.new_cipher(MSE.key_b(s, info_hash))

    with {:ok, ia} <- read_initiator_payload(socket, recv_cipher, timeout),
         :ok <- send_encrypted_reply(socket, send_cipher) do
      {:ok, %{recv: recv_cipher, send: send_cipher, leftover: ia}}
    end
  end

  # Decrypt A's ENCRYPT(VC, crypto_provide, len(PadC), PadC, len(IA), IA).
  defp read_initiator_payload(socket, cipher, timeout) do
    with {:ok, head} <- recv_exact(socket, 14, timeout) do
      <<vc::bytes-size(8), _provide::32, pad_len::16>> = MSE.crypt(cipher, head)

      if vc == @vc do
        read_initiator_after_vc(socket, cipher, pad_len, timeout)
      else
        {:error, :mse_bad_vc}
      end
    end
  end

  defp read_initiator_after_vc(socket, cipher, pad_len, timeout) do
    with {:ok, _padc} <- recv_exact_maybe_decrypt(socket, cipher, pad_len, timeout),
         {:ok, ia_len_enc} <- recv_exact(socket, 2, timeout) do
      <<ia_len::16>> = MSE.crypt(cipher, ia_len_enc)
      recv_exact_decrypt(socket, cipher, ia_len, timeout)
    end
  end

  # B -> A step 4: ENCRYPT(VC, crypto_select = rc4, len(PadD)=0). We prefer RC4.
  # Yb + PadB already went out (step 2), so this is only the encrypted reply.
  defp send_encrypted_reply(socket, cipher) do
    select = <<0::24, MSE.crypto_rc4()>>
    payload = MSE.crypt(cipher, <<@vc::binary, select::binary, 0::16>>)
    Transport.send(socket, payload)
  end

  @doc """
  Build a resolver for `respond/2` that matches the obfuscated info hash against
  a list of candidate torrent hashes (`HASH('req2', SKEY) == req2_3 xor
  HASH('req3', S)`).
  """
  @spec resolver([Torrent.hash()]) :: (binary(), binary() -> Torrent.hash() | nil)
  def resolver(candidate_hashes) do
    fn s, req2_3 ->
      target = MSE.xor(req2_3, MSE.hash("req3", [s]))
      Enum.find(candidate_hashes, fn h -> MSE.hash("req2", [h]) == target end)
    end
  end

  # ---- shared IO --------------------------------------------------------------

  defp pad, do: :crypto.strong_rand_bytes(:rand.uniform(96) - 1)

  # Scan the raw stream for `marker`, dropping everything before it (padding).
  defp scan_for(socket, marker, timeout) do
    case recv_exact(socket, byte_size(marker), timeout) do
      {:ok, window} -> scan_loop(socket, marker, window, 0, timeout)
      {:error, _} = error -> error
    end
  end

  defp scan_loop(_socket, marker, marker, _consumed, _timeout), do: :ok

  defp scan_loop(socket, marker, window, consumed, timeout) do
    if consumed >= @max_scan do
      {:error, :mse_sync_failed}
    else
      case recv_exact(socket, 1, timeout) do
        {:ok, byte} ->
          <<_drop::8, rest::binary>> = window
          scan_loop(socket, marker, rest <> byte, consumed + 1, timeout)

        {:error, _} = error ->
          error
      end
    end
  end

  defp recv_exact(_socket, 0, _timeout), do: {:ok, <<>>}

  defp recv_exact(socket, len, timeout) when len > 0 do
    Transport.recv(socket, len, timeout)
  end

  defp recv_exact_maybe_decrypt(_socket, _cipher, 0, _timeout), do: {:ok, <<>>}

  defp recv_exact_maybe_decrypt(socket, cipher, len, timeout) do
    with {:ok, enc} <- recv_exact(socket, len, timeout) do
      _ = MSE.crypt(cipher, enc)
      {:ok, <<>>}
    end
  end

  defp recv_exact_decrypt(socket, cipher, len, timeout) do
    with {:ok, enc} <- recv_exact(socket, len, timeout) do
      {:ok, MSE.crypt(cipher, enc)}
    end
  end
end

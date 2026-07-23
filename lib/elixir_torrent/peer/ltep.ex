defmodule Peer.LTEP do
  @moduledoc """
  BitTorrent Extension Protocol (BEP 10 / LTEP).

  Provides reserved-bit detection, extended message framing (bittorrent message id 20),
  handshake encode/decode, per-peer extension id mapping, and re-handshake merge.
  Individual extensions (e.g. BEP 9 `ut_metadata`) register via `Peer.LTEP.Extension`.
  """

  alias Peer.LTEP.{Handshake, Session}

  # BEP 10: extended messages use bittorrent wire message id 20.
  @message_id 20
  # BEP 10: extended message id 0 is the extension handshake.
  @handshake_id 0

  @default_recv_timeout 30_000

  @doc """
  Whether the peer set BEP 10 extension-protocol bit 20 in the reserved bytes.

  BEP 10 / libtorrent: `(reserved[5] & 0x10) != 0` — byte index 5 (sixth byte),
  bit 4 within that byte. Must use a bitmask, not an exact byte match, because peers
  may set other bits in the same byte (e.g. libtorrent uses `0x10` at index 5).
  """
  @spec extension_protocol?(Peer.reserved()) :: boolean()
  def extension_protocol?(<<_::40, byte5, _::16>>), do: Bitwise.band(byte5, 0x10) != 0
  def extension_protocol?(_), do: false

  @doc false
  @spec message_id() :: 20
  def message_id, do: @message_id

  @doc false
  @spec handshake_id() :: 0
  def handshake_id, do: @handshake_id

  @doc """
  Sends an LTEP extended message (BEP 10 § extended message layout).

  `extended_id` is 0 for handshake or the peer-specific id from their `m` dictionary
  when sending extension payloads to that peer.
  """
  @spec send_extended(:gen_tcp.socket(), non_neg_integer(), iodata()) :: :ok | {:error, term()}
  def send_extended(socket, extended_id, payload)
      when is_port(socket) and is_integer(extended_id) and extended_id >= 0 do
    case extended_message_wire(extended_id, payload) do
      wire -> :gen_tcp.send(socket, wire)
    end
  end

  @doc false
  @spec send_extended(Peer.key(), non_neg_integer(), iodata()) :: :ok | {:error, term()}
  def send_extended(key, extended_id, payload)
      when is_tuple(key) and is_integer(extended_id) and extended_id >= 0 do
    Peer.Sender.socket_send_raw(key, extended_message_wire(extended_id, payload))
  end

  @doc """
  Builds the on-wire bytes for a BEP 10 extended message (for tests and tracing).

  Layout: 4-byte big-endian length, message id 20, extended id, payload.
  The length covers the message id, extended id, and payload (BEP 3).
  """
  @spec extended_message_wire(non_neg_integer(), iodata()) :: binary()
  def extended_message_wire(extended_id, payload)
      when is_integer(extended_id) and extended_id >= 0 do
    payload = IO.iodata_to_binary(payload)
    # BEP 3 length prefix covers message id + extended id + payload.
    length = 1 + 1 + byte_size(payload)
    <<length::32, @message_id, extended_id, payload::binary>>
  end

  @doc """
  Receives one LTEP extended message.

  Returns `{:ok, message_id, extended_id, payload}` or `{:error, reason}`.
  """
  @spec recv_extended(:gen_tcp.socket() | Peer.key(), non_neg_integer()) ::
          {:ok, pos_integer(), non_neg_integer(), binary()} | {:error, term()}
  def recv_extended(socket_or_key, timeout \\ @default_recv_timeout)

  def recv_extended(socket, timeout) when is_port(socket) do
    with {:ok, <<length::32>>} <- :gen_tcp.recv(socket, 4, timeout),
         true <- length >= 2,
         {:ok, message} <- :gen_tcp.recv(socket, length, timeout),
         <<message_id, extended_id, payload::binary>> <- message do
      {:ok, message_id, extended_id, payload}
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  end

  def recv_extended(key, timeout) when is_tuple(key) do
    with {:ok, <<length::32>>} <- Peer.Sender.socket_recv(key, 4, timeout),
         true <- length >= 2,
         {:ok, message} <- Peer.Sender.socket_recv(key, length, timeout),
         <<message_id, extended_id, payload::binary>> <- message do
      {:ok, message_id, extended_id, payload}
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  end

  @doc """
  Sends our extension handshake and reads the peer's first reply handshake.

  Returns `{:ok, session}` with peer ids merged, or an error tuple.
  """
  @spec handshake_exchange(:gen_tcp.socket() | Peer.key(), Session.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def handshake_exchange(socket_or_key, session, opts \\ [])

  def handshake_exchange(socket, %Session{} = session, opts) when is_port(socket) do
    outbound = Session.outbound_handshake(session, opts)
    timeout = Keyword.get(opts, :timeout, @default_recv_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- send_extended(socket, @handshake_id, outbound),
         {:ok, reply} <- recv_until_peer_handshake(socket, deadline),
         {:ok, peer_hs} <- Handshake.decode(reply) do
      {:ok, Session.apply_peer_handshake(session, peer_hs)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_ltep}
    end
  end

  def handshake_exchange(key, %Session{} = session, opts) when is_tuple(key) do
    outbound = Session.outbound_handshake(session, opts)
    timeout = Keyword.get(opts, :timeout, @default_recv_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    with :ok <- send_extended(key, @handshake_id, outbound),
         {:ok, reply} <- recv_until_peer_handshake(key, deadline),
         {:ok, peer_hs} <- Handshake.decode(reply) do
      {:ok, Session.apply_peer_handshake(session, peer_hs)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_ltep}
    end
  end

  @doc """
  Merges a subsequent in-band extension handshake into session state (BEP 10 re-handshake).
  """
  @spec merge_handshake(Session.t(), binary()) :: Session.t()
  def merge_handshake(%Session{} = session, payload) when is_binary(payload) do
    case Handshake.decode(payload) do
      {:ok, peer_hs} -> Session.apply_peer_handshake(session, peer_hs)
      _ -> session
    end
  end

  # Peers often send choke/bitfield/keepalive before the BEP 10 handshake reply.
  @spec recv_until_peer_handshake(:gen_tcp.socket() | Peer.key(), integer()) ::
          {:ok, binary()} | {:error, term()}
  defp recv_until_peer_handshake(socket_or_key, deadline)

  defp recv_until_peer_handshake(socket, deadline) when is_port(socket) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      poll = min(deadline - now, 5_000)

      case recv_framed_message(socket, poll) do
        {:ok, {:extended, @handshake_id, payload}} ->
          {:ok, payload}

        {:ok, _} ->
          recv_until_peer_handshake(socket, deadline)

        {:error, :timeout} ->
          recv_until_peer_handshake(socket, deadline)

        {:error, _} = error ->
          error
      end
    end
  end

  defp recv_until_peer_handshake(key, deadline) when is_tuple(key) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      poll = min(deadline - now, 5_000)

      case recv_framed_message(key, poll) do
        {:ok, {:extended, @handshake_id, payload}} ->
          {:ok, payload}

        {:ok, _} ->
          recv_until_peer_handshake(key, deadline)

        {:error, :timeout} ->
          recv_until_peer_handshake(key, deadline)

        {:error, _} = error ->
          error
      end
    end
  end

  @type framed ::
          :keepalive
          | {:standard, pos_integer(), binary()}
          | {:extended, non_neg_integer(), binary()}

  @spec recv_framed_message(:gen_tcp.socket(), non_neg_integer()) ::
          {:ok, framed()} | {:error, term()}
  defp recv_framed_message(socket, timeout) when is_port(socket) do
    with {:ok, <<length::32>>} <- :gen_tcp.recv(socket, 4, timeout) do
      read_framed_body(socket, length, timeout)
    end
  end

  @spec recv_framed_message(Peer.key(), non_neg_integer()) ::
          {:ok, framed()} | {:error, term()}
  defp recv_framed_message(key, timeout) when is_tuple(key) do
    with {:ok, <<length::32>>} <- Peer.Sender.socket_recv(key, 4, timeout) do
      read_framed_body(key, length, timeout)
    end
  end

  @spec read_framed_body(:gen_tcp.socket() | Peer.key(), non_neg_integer(), non_neg_integer()) ::
          {:ok, framed()} | {:error, term()}
  defp read_framed_body(_socket, 0, _timeout), do: {:ok, :keepalive}

  defp read_framed_body(socket, length, timeout) when is_port(socket) and length > 0 do
    body_timeout = max(timeout, min(@default_recv_timeout, max(length, 1_000)))

    with {:ok, message} <- :gen_tcp.recv(socket, length, body_timeout) do
      parse_framed_body(message)
    end
  end

  defp read_framed_body(key, length, timeout) when is_tuple(key) and length > 0 do
    body_timeout = max(timeout, min(@default_recv_timeout, max(length, 1_000)))

    with {:ok, message} <- Peer.Sender.socket_recv(key, length, body_timeout) do
      parse_framed_body(message)
    end
  end

  @spec parse_framed_body(binary()) :: {:ok, framed()} | {:error, term()}
  defp parse_framed_body(<<@message_id, extended_id, payload::binary>>) do
    {:ok, {:extended, extended_id, payload}}
  end

  defp parse_framed_body(<<message_id, rest::binary>>) do
    {:ok, {:standard, message_id, rest}}
  end

  defp parse_framed_body(_), do: {:error, :invalid_message}
end

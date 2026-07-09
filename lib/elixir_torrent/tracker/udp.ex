defmodule Tracker.UDP do
  @moduledoc """
  BitTorrent UDP tracker wire format (BEP 15).

  Pure encode/decode helpers for connect (action 0), announce (1), scrape (2),
  and error (3) packets. Network I/O and retransmission live in `Tracker`.
  """

  alias Tracker.Response

  @protocol_id <<0x41727101980::64>>
  @action_connect <<0::32>>
  @action_announce <<1::32>>
  @action_scrape <<2::32>>
  @action_error <<3::32>>

  # BEP 15 § Time outs — 15 * 2^n seconds for n in 0..8 (3840 s cap).
  @initial_backoff_seconds 15
  @max_backoff_attempt 8

  # BEP 15 § UDP connections — client may reuse connection_id for one minute.
  @connection_id_lifetime_ms 60_000

  # BEP 15 § Scrape — "up to about 74 torrents" per request.
  @max_scrape_hashes 74

  @type connection_id :: <<_::64>>
  @type transaction_id :: <<_::32>>
  @type scrape_stats :: %{
          seeders: non_neg_integer(),
          completed: non_neg_integer(),
          leechers: non_neg_integer()
        }
  @type family :: :inet | :inet6

  @doc "BEP 15 connect request magic constant `protocol_id`."
  @spec protocol_id() :: <<_::64>>
  def protocol_id(), do: @protocol_id

  @doc "BEP 15 § Time outs — backoff interval in seconds for attempt `n` (0..8)."
  @spec backoff_timeout_seconds(0..8) :: pos_integer()
  def backoff_timeout_seconds(n) when n in 0..@max_backoff_attempt do
    @initial_backoff_seconds * trunc(:math.pow(2, n))
  end

  @doc "Highest retransmission attempt index (inclusive) before giving up."
  @spec max_backoff_attempt() :: 0..8
  def max_backoff_attempt(), do: @max_backoff_attempt

  @doc "BEP 15 § UDP connections — connection_id reuse window in milliseconds."
  @spec connection_id_lifetime_ms() :: pos_integer()
  def connection_id_lifetime_ms(), do: @connection_id_lifetime_ms

  @doc "Maximum info_hashes per scrape request (BEP 15 § Scrape)."
  @spec max_scrape_hashes() :: pos_integer()
  def max_scrape_hashes(), do: @max_scrape_hashes

  @doc """
  BEP 15 § Connect — 16-byte connect request (protocol_id, action=0, transaction_id).
  """
  @spec encode_connect(transaction_id()) :: iodata()
  def encode_connect(transaction_id) when byte_size(transaction_id) == 4 do
    [@protocol_id, @action_connect, transaction_id]
  end

  @doc """
  BEP 15 § Connect — parse connect response (min 16 bytes, action=0, matching transaction_id).
  """
  @spec decode_connect_response(binary(), transaction_id()) ::
          {:ok, connection_id()}
          | {:error, :invalid_packet | :transaction_mismatch | :unexpected_action}
  def decode_connect_response(body, transaction_id) when byte_size(transaction_id) == 4 do
    case body do
      _ when byte_size(body) < 16 ->
        {:error, :invalid_packet}

      <<@action_error, ^transaction_id::binary-size(4), message::binary>> ->
        {:error, message}

      <<@action_connect, ^transaction_id::binary-size(4), connection_id::binary-size(8)>> ->
        {:ok, connection_id}

      <<action::32, ^transaction_id::binary-size(4), _::binary>> when action in 0..3 ->
        {:error, :unexpected_action}

      _ ->
        {:error, :transaction_mismatch}
    end
  end

  @doc """
  BEP 15 § Announce — 98-byte IPv4 announce request.
  """
  @spec encode_announce(
          connection_id(),
          transaction_id(),
          Torrent.hash(),
          <<_::160>>,
          keyword()
        ) :: iodata()
  def encode_announce(connection_id, transaction_id, hash, peer_id, fields)
      when byte_size(connection_id) == 8 and byte_size(transaction_id) == 4 and
             byte_size(hash) == 20 and byte_size(peer_id) == 20 and is_list(fields) do
    uploaded = Keyword.fetch!(fields, :uploaded)
    downloaded = Keyword.fetch!(fields, :downloaded)
    left = Keyword.fetch!(fields, :left)
    event = Keyword.fetch!(fields, :event)
    ip_field = Keyword.fetch!(fields, :ip_field)
    key = Keyword.fetch!(fields, :key)
    num_want = Keyword.fetch!(fields, :num_want)
    port = Keyword.fetch!(fields, :port)

    [
      connection_id,
      @action_announce,
      transaction_id,
      hash,
      peer_id,
      <<downloaded::64>>,
      <<left::64>>,
      <<uploaded::64>>,
      <<event::32>>,
      ip_field,
      key,
      <<num_want::32>>,
      <<port::16>>
    ]
  end

  @doc """
  BEP 15 § Announce — parse announce response (min 20 bytes; compact peers follow header).
  """
  @spec decode_announce_response(binary(), transaction_id(), family()) ::
          {:ok, Response.t()}
          | {:error, :invalid_packet | :transaction_mismatch | :unexpected_action | String.t()}
  def decode_announce_response(body, transaction_id, family)
      when byte_size(transaction_id) == 4 and family in [:inet, :inet6] do
    case body do
      _ when byte_size(body) < 20 ->
        {:error, :invalid_packet}

      <<@action_error, ^transaction_id::binary-size(4), message::binary>> ->
        {:error, message}

      <<@action_announce, ^transaction_id::binary-size(4), interval::32, leechers::32,
        seeders::32, peers::binary>> ->
        {:ok,
         %Response{
           interval: interval,
           complete: seeders,
           incomplete: leechers,
           peers: parse_compact_peers(peers, family)
         }}

      <<action::32, ^transaction_id::binary-size(4), _::binary>> when action in 0..3 ->
        {:error, :unexpected_action}

      _ ->
        {:error, :transaction_mismatch}
    end
  end

  @doc """
  BEP 15 § Scrape — encode scrape request for up to #{@max_scrape_hashes} info_hashes.
  """
  @spec encode_scrape(connection_id(), transaction_id(), [Torrent.hash()]) :: iodata()
  def encode_scrape(_connection_id, _transaction_id, []),
    do: raise(ArgumentError, "empty scrape list")

  def encode_scrape(connection_id, transaction_id, hashes)
      when byte_size(connection_id) == 8 and byte_size(transaction_id) == 4 and is_list(hashes) and
             length(hashes) <= @max_scrape_hashes do
    if Enum.all?(hashes, &(byte_size(&1) == 20)) do
      [connection_id, @action_scrape, transaction_id | hashes]
    else
      raise ArgumentError, "each info_hash must be 20 bytes"
    end
  end

  @doc """
  BEP 15 § Scrape — parse scrape response into per-hash stats (order matches request).
  """
  @spec decode_scrape_response(binary(), transaction_id(), pos_integer()) ::
          {:ok, [scrape_stats()]}
          | {:error, :invalid_packet | :transaction_mismatch | :unexpected_action | String.t()}
  def decode_scrape_response(body, transaction_id, hash_count)
      when byte_size(transaction_id) == 4 and hash_count >= 1 do
    expected_size = 8 + 12 * hash_count

    case body do
      _ when byte_size(body) < 8 ->
        {:error, :invalid_packet}

      _ when byte_size(body) < expected_size ->
        {:error, :invalid_packet}

      <<@action_error, ^transaction_id::binary-size(4), message::binary>> ->
        {:error, message}

      <<@action_scrape, ^transaction_id::binary-size(4), rest::binary>> ->
        {:ok, parse_scrape_entries([], rest, hash_count)}

      <<action::32, ^transaction_id::binary-size(4), _::binary>> when action in 0..3 ->
        {:error, :unexpected_action}

      _ ->
        {:error, :transaction_mismatch}
    end
  end

  @doc """
  BEP 15 § Errors — parse error response (action=3, matching transaction_id, message tail).
  """
  @spec decode_error_response(binary(), transaction_id()) ::
          {:error, String.t()}
          | {:error, :invalid_packet | :transaction_mismatch | :unexpected_action}
  def decode_error_response(body, transaction_id) when byte_size(transaction_id) == 4 do
    case body do
      _ when byte_size(body) < 8 ->
        {:error, :invalid_packet}

      <<@action_error, ^transaction_id::binary-size(4), message::binary>> ->
        {:error, message}

      <<action::32, ^transaction_id::binary-size(4), _::binary>> when action in 0..3 ->
        {:error, :unexpected_action}

      _ ->
        {:error, :transaction_mismatch}
    end
  end

  @doc """
  Classify an inbound UDP body for a recv loop.

  Returns `:ignore` for short packets or transaction_id mismatches (BEP 15: validate txn id).
  """
  @spec classify_response(binary(), transaction_id(), keyword()) ::
          :ignore
          | {:ok, connection_id()}
          | {:ok, Response.t()}
          | {:ok, [scrape_stats()]}
          | {:error, String.t() | atom()}
  def classify_response(body, transaction_id, opts) when byte_size(transaction_id) == 4 do
    expected = Keyword.get(opts, :expected, :announce)
    family = Keyword.get(opts, :family, :inet)
    hash_count = Keyword.get(opts, :hash_count, 1)

    case expected do
      :connect ->
        case decode_connect_response(body, transaction_id) do
          {:ok, _} = ok -> ok
          {:error, :transaction_mismatch} -> :ignore
          {:error, reason} -> {:error, reason}
        end

      :announce ->
        case decode_announce_response(body, transaction_id, family) do
          {:ok, _} = ok -> ok
          {:error, :transaction_mismatch} -> :ignore
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      :scrape ->
        case decode_scrape_response(body, transaction_id, hash_count) do
          {:ok, _} = ok -> ok
          {:error, :transaction_mismatch} -> :ignore
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Parse compact peer bytes from an announce response (BEP 15 § Announce / IPv6)."
  @spec parse_compact_peers(binary(), family()) :: [Peer.t()]
  def parse_compact_peers(peers, :inet), do: parse_compact_ipv4([], peers)
  def parse_compact_peers(peers, :inet6), do: parse_compact_ipv6([], peers)

  @spec parse_compact_ipv4([Peer.t()], binary()) :: [Peer.t()]
  def parse_compact_ipv4(res, <<>>), do: Enum.reverse(res)

  def parse_compact_ipv4(res, <<a, b, c, d, port::16, rest::binary>>) do
    parse_compact_ipv4([%Peer{ip: {a, b, c, d}, port: port} | res], rest)
  end

  def parse_compact_ipv4(res, _rest), do: Enum.reverse(res)

  @spec parse_compact_ipv6([Peer.t()], binary()) :: [Peer.t()]
  def parse_compact_ipv6(res, <<>>), do: Enum.reverse(res)

  def parse_compact_ipv6(
        res,
        <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16, port::16, rest::binary>>
      ) do
    parse_compact_ipv6([%Peer{ip: {s1, s2, s3, s4, s5, s6, s7, s8}, port: port} | res], rest)
  end

  def parse_compact_ipv6(res, _rest), do: Enum.reverse(res)

  defp parse_scrape_entries(acc, _rest, 0), do: Enum.reverse(acc)

  defp parse_scrape_entries(acc, <<seeders::32, completed::32, leechers::32, rest::binary>>, n) do
    parse_scrape_entries(
      [%{seeders: seeders, completed: completed, leechers: leechers} | acc],
      rest,
      n - 1
    )
  end

  defp parse_scrape_entries(acc, _rest, _n), do: Enum.reverse(acc)
end

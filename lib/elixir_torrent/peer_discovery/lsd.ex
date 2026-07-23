defmodule PeerDiscovery.LSD do
  @moduledoc """
  BEP 14 — Local Service Discovery.

  Multicasts `BT-SEARCH` announcements over UDP so peers on the same LAN can
  find us without a tracker or the DHT, and offers incoming BT-SEARCH peers
  to `Peer.ConnectionManager`.

  Currently IPv4 only. The BEP-14 IPv6 group `ff15::efc0:988f` is spec but
  Erlang's `:add_membership` for `:inet6` sockets is more fragile across
  platforms — can be layered on once the v4 path proves itself.

  Private torrents (BEP 27) are skipped in both directions.

  All errors are non-fatal — LSD is a best-effort discovery channel that must
  never crash the peer-discovery pipeline. If the multicast socket cannot be
  opened at boot (port 6771 held by another client on the box, no multicast
  route, etc.) the process runs as a no-op.
  """

  use GenServer

  require Logger

  alias PeerDiscovery.Announce

  # BEP 14 § "Discovery" — well-known multicast group and port. TTL 4 keeps
  # the packet inside the local administrative zone (default was 1, which
  # can be filtered at the first hop of some managed switches).
  @port 6771
  @group {239, 192, 152, 143}
  @multicast_ttl 4
  # BEP 14 § "Client behaviour" — clients MUST NOT announce more than once
  # per minute. libtorrent/qBittorrent default is ~5 minutes; we match.
  @interval_ms 5 * 60 * 1_000
  @initial_delay_ms 10_000
  # BEP 14 allows a single BT-SEARCH message to batch multiple `Infohash:`
  # lines. Cap per-message to keep the packet under a 1500-byte Ethernet MTU
  # (each Infohash line is ~50 bytes; 20 hashes ≈ 1 KB payload).
  @max_hashes_per_message 20

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Random cookie lets us drop the multicast loopback of our own messages
    # without a race-prone source-address check (the wire header claims what
    # the sender chose, but the LAN interface can rewrite it).
    cookie = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

    socket = open_socket()

    state = %{cookie: cookie, socket: socket}

    if socket == nil do
      Logger.info("[lsd] disabled — v4 multicast socket unavailable")
    else
      Logger.info("[lsd] listening cookie=#{cookie} port=#{@port} interval_ms=#{@interval_ms}")
      Process.send_after(self(), :announce, @initial_delay_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:announce, %{socket: nil} = state), do: {:noreply, state}

  def handle_info(:announce, state) do
    Process.send_after(self(), :announce, @interval_ms)
    broadcast(state)
    {:noreply, state}
  end

  def handle_info({:udp, socket, ip, _src_port, packet}, %{socket: socket} = state) do
    handle_packet(packet, ip, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}) when is_port(socket) do
    _ = :gen_udp.close(socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── public helpers exposed for tests ────────────────────────────────────

  @doc false
  @spec build_message([Torrent.hash()], :inet.port_number(), binary()) :: iodata()
  def build_message(hashes, port, cookie) do
    {ip1, ip2, ip3, ip4} = @group
    host = "#{ip1}.#{ip2}.#{ip3}.#{ip4}:#{@port}"

    infohash_lines =
      Enum.map(hashes, fn h ->
        ["Infohash: ", Torrent.hex_encoded_hash(h), "\r\n"]
      end)

    [
      "BT-SEARCH * HTTP/1.1\r\n",
      "Host: ",
      host,
      "\r\n",
      "Port: ",
      Integer.to_string(port),
      "\r\n",
      infohash_lines,
      "cookie: ",
      cookie,
      "\r\n\r\n\r\n"
    ]
  end

  @doc false
  @spec parse_message(binary()) :: {:ok, map()} | :error
  def parse_message(packet) when is_binary(packet) do
    case packet do
      <<"BT-SEARCH ", _rest::binary>> ->
        [_request_line | header_lines] = String.split(packet, "\r\n")

        acc =
          Enum.reduce(header_lines, %{hashes: [], port: nil, cookie: nil}, fn line, a ->
            case line do
              "" ->
                a

              _ ->
                case String.split(line, ":", parts: 2) do
                  [name, value] ->
                    apply_header(a, String.downcase(String.trim(name)), String.trim(value))

                  _ ->
                    a
                end
            end
          end)

        if is_integer(acc.port) and acc.hashes != [] do
          {:ok, %{acc | hashes: Enum.reverse(acc.hashes)}}
        else
          :error
        end

      _ ->
        :error
    end
  end

  def parse_message(_), do: :error

  @spec apply_header(map(), String.t(), String.t()) :: map()
  defp apply_header(acc, "port", value) do
    case Integer.parse(value) do
      {p, ""} when p > 0 and p < 65_536 -> %{acc | port: p}
      _ -> acc
    end
  end

  defp apply_header(acc, "infohash", value) do
    case decode_hex_hash(value) do
      {:ok, hash} -> %{acc | hashes: [hash | acc.hashes]}
      _ -> acc
    end
  end

  defp apply_header(acc, "cookie", value), do: %{acc | cookie: value}
  defp apply_header(acc, _, _), do: acc

  @spec decode_hex_hash(binary()) :: {:ok, binary()} | :error
  defp decode_hex_hash(hex) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == 20 -> {:ok, bin}
      _ -> :error
    end
  end

  defp decode_hex_hash(_), do: :error

  # ── internals ───────────────────────────────────────────────────────────

  @spec open_socket() :: :gen_udp.socket() | nil
  defp open_socket do
    opts = [
      :binary,
      {:active, true},
      {:reuseaddr, true},
      {:reuseport, true},
      {:multicast_ttl, @multicast_ttl},
      # Loopback on so multiple BitTorrent processes on the same host can find
      # each other via LSD (libtorrent does the same). Our cookie filter drops
      # our own echoes.
      {:multicast_loop, true},
      {:add_membership, {@group, {0, 0, 0, 0}}}
    ]

    case :gen_udp.open(@port, opts) do
      {:ok, socket} ->
        socket

      {:error, reason} ->
        Logger.warning("[lsd] socket open failed port=#{@port} reason=#{inspect(reason)}")
        nil
    end
  end

  @spec broadcast(map()) :: :ok
  defp broadcast(%{socket: socket, cookie: cookie}) do
    hashes = active_public_hashes()

    if hashes == [] do
      :ok
    else
      port = Acceptor.port()

      hashes
      |> Enum.chunk_every(@max_hashes_per_message)
      |> Enum.each(fn chunk ->
        payload = build_message(chunk, port, cookie)
        _ = :gen_udp.send(socket, @group, @port, payload)
      end)

      Logger.debug("[lsd] announced hashes=#{length(hashes)} port=#{port}")
    end
  catch
    kind, err ->
      Logger.debug("[lsd] announce failed kind=#{inspect(kind)} reason=#{inspect(err)}")
      :ok
  end

  @spec active_public_hashes() :: [Torrent.hash()]
  defp active_public_hashes do
    Registry
    |> Registry.select([{{{:"$1", PeerDiscovery.Announce}, :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&private_or_dead?/1)
  end

  @spec private_or_dead?(Torrent.hash()) :: boolean()
  defp private_or_dead?(hash) do
    # `Registry.select/2` already proved the Announce process is alive; a
    # crash between select and this call surfaces as `Announce.private?/1`
    # returning `false` (its own :exit rescue), and the caller then treats
    # this hash as public. That's fine for LSD — dropped hashes on the next
    # tick self-correct.
    Announce.private?(hash)
  end

  @spec handle_packet(binary(), :inet.ip_address(), map()) :: :ok
  defp handle_packet(packet, source_ip, %{cookie: our_cookie}) do
    with {:ok, %{port: port, hashes: hashes, cookie: cookie}} <- parse_message(packet),
         true <- cookie != our_cookie do
      Enum.each(hashes, fn hash -> offer_peer(hash, source_ip, port) end)
      :ok
    else
      _ -> :ok
    end
  catch
    _kind, _err -> :ok
  end

  @spec offer_peer(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: :ok
  defp offer_peer(hash, ip, port) do
    # Confirm this hash is one we're actually tracking (Registry lookup) AND
    # it isn't private (BEP 27). If Announce is dead the whole flow no-ops.
    with pid when is_pid(pid) <-
           Registry.whereis_name({Registry, {hash, PeerDiscovery.Announce}}),
         false <- Announce.private?(hash) do
      peer = %Peer{ip: ip, port: port}
      _ = Peer.ConnectionManager.offer_peers(hash, [peer])

      Logger.debug(
        "[lsd] discovered hash=#{Torrent.hex_encoded_hash(hash)} peer=#{Acceptor.format_ip(ip)}:#{port} announce=#{inspect(pid)}"
      )

      :ok
    else
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end
end

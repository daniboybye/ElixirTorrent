defmodule PeerDiscovery.LSD do
  @moduledoc """
  BEP 14 — Local Service Discovery.

  Multicasts `BT-SEARCH` announcements over IPv4 and IPv6 UDP so peers on the
  same LAN can find us without a tracker or the DHT, and offers incoming
  BT-SEARCH peers to `Peer.ConnectionManager`.

  Private torrents (BEP 27) are skipped in both directions.

  All errors are non-fatal — LSD is a best-effort discovery channel that must
  never crash the peer-discovery pipeline. If the multicast socket cannot be
  opened at boot (port 6771 held by another client on the box, no multicast
  route, etc.) the process runs as a no-op.
  """

  use GenServer

  alias PeerDiscovery.Announce

  require Logger

  # BEP 14 § "Discovery" — well-known multicast groups and port. TTL 4 keeps
  # the packet inside the local administrative zone (default was 1, which
  # can be filtered at the first hop of some managed switches).
  @port 6771
  @ipv4_group {239, 192, 152, 143}
  @ipv6_group {0xFF15, 0, 0, 0, 0, 0, 0xEFC0, 0x988F}
  @multicast_ttl 4
  # BEP 14 § "Client behaviour" — clients MUST NOT announce more than once
  # per minute. libtorrent/qBittorrent default is ~5 minutes; we match.
  @interval_ms 5 * 60 * 1_000
  @min_announce_interval_ms 60_000
  @interface_refresh_ms 30_000
  @initial_delay_ms 10_000
  # BEP 14 allows a single BT-SEARCH message to batch multiple `Infohash:`
  # lines. Cap per-message to keep the packet under a 1500-byte Ethernet MTU
  # (each Infohash line is ~50 bytes; 20 hashes ≈ 1 KB payload).
  @max_hashes_per_message 20

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    # Random cookie lets us drop the multicast loopback of our own messages
    # without a race-prone source-address check (the wire header claims what
    # the sender chose, but the LAN interface can rewrite it).
    cookie = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

    interfaces = Acceptor.multicast_interfaces()
    sockets = open_sockets(interfaces)

    state = %{cookie: cookie, sockets: sockets, interfaces: interfaces, announce_queue: []}

    if Enum.all?(sockets, fn {_family, socket} -> socket == nil end) do
      Logger.info("[lsd] disabled — multicast sockets unavailable")
    else
      Logger.info(
        "[lsd] listening cookie=#{cookie} port=#{@port} interval_ms=#{@interval_ms} " <>
          "v4_interfaces=#{length(interfaces.inet)} v6_interfaces=#{length(interfaces.inet6)}"
      )
    end

    Process.send_after(self(), :announce, @initial_delay_ms)
    Process.send_after(self(), :refresh_interfaces, @interface_refresh_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:announce, state) do
    state = refresh_interfaces(state)

    queue =
      active_public_hashes()
      |> announce_schedule()

    announce_next(%{state | announce_queue: queue})
  end

  def handle_info(:announce_next, state), do: announce_next(state)

  def handle_info(:refresh_interfaces, state) do
    Process.send_after(self(), :refresh_interfaces, @interface_refresh_ms)
    {:noreply, refresh_interfaces(state)}
  end

  def handle_info({:udp, socket, ip, _src_port, packet}, state) do
    if socket in Map.values(state.sockets), do: handle_packet(packet, ip, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{sockets: sockets}) do
    close_sockets(sockets)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── public helpers exposed for tests ────────────────────────────────────

  @doc false
  @spec build_message([Torrent.hash()], :inet.port_number(), binary()) :: iodata()
  def build_message(hashes, port, cookie) do
    build_message(hashes, port, cookie, :inet)
  end

  @doc false
  @spec build_message([Torrent.hash()], :inet.port_number(), binary(), Acceptor.ip_family()) ::
          iodata()
  def build_message(hashes, port, cookie, family) do
    host =
      case family do
        :inet ->
          {ip1, ip2, ip3, ip4} = @ipv4_group
          "#{ip1}.#{ip2}.#{ip3}.#{ip4}:#{@port}"

        :inet6 ->
          "[ff15::efc0:988f]:#{@port}"
      end

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
  @spec announce_schedule([Torrent.hash()]) :: [{non_neg_integer(), [Torrent.hash()]}]
  def announce_schedule(hashes) do
    hashes
    |> Enum.chunk_every(@max_hashes_per_message)
    |> Enum.with_index(fn chunk, index -> {index * @min_announce_interval_ms, chunk} end)
  end

  @doc false
  @spec next_cycle_delay(non_neg_integer()) :: pos_integer()
  def next_cycle_delay(last_offset_ms) do
    max(@min_announce_interval_ms, @interval_ms - last_offset_ms)
  end

  @doc false
  @spec multicast_targets(Acceptor.multicast_interfaces()) ::
          [{Acceptor.ip_family(), :inet.ip4_address() | non_neg_integer(), :inet.ip_address()}]
  def multicast_targets(interfaces) do
    Enum.map(interfaces.inet, &{:inet, &1, @ipv4_group}) ++
      Enum.map(interfaces.inet6, &{:inet6, &1, @ipv6_group})
  end

  @doc false
  @spec announce_datagrams(
          [Torrent.hash()],
          :inet.port_number(),
          binary(),
          Acceptor.multicast_interfaces()
        ) ::
          [
            {Acceptor.ip_family(), :inet.ip4_address() | non_neg_integer(), :inet.ip_address(),
             iodata()}
          ]
  def announce_datagrams(hashes, port, cookie, interfaces) do
    Enum.map(multicast_targets(interfaces), fn {family, interface, group} ->
      {family, interface, group, build_message(hashes, port, cookie, family)}
    end)
  end

  @doc false
  @spec membership_option(Acceptor.ip_family(), :inet.ip4_address() | non_neg_integer()) ::
          :gen_udp.option()
  def membership_option(:inet, interface), do: {:add_membership, {@ipv4_group, interface}}
  def membership_option(:inet6, interface), do: {:add_membership, {@ipv6_group, interface}}

  @doc false
  @spec parse_message(binary()) :: {:ok, map()} | :error
  def parse_message(packet) when is_binary(packet) do
    case packet do
      <<"BT-SEARCH ", _rest::binary>> ->
        [_request_line | header_lines] = String.split(packet, "\r\n")

        acc =
          Enum.reduce(header_lines, %{hashes: [], port: nil, cookie: nil}, fn line, a ->
            parse_lsd_header_line(a, line)
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

  @spec parse_lsd_header_line(map(), String.t()) :: map()
  defp parse_lsd_header_line(acc, ""), do: acc

  defp parse_lsd_header_line(acc, line) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        apply_header(acc, String.downcase(String.trim(name)), String.trim(value))

      _ ->
        acc
    end
  end

  @doc false
  @spec decode_packet(binary(), :inet.ip_address(), binary()) ::
          [{Torrent.hash(), :inet.ip_address(), :inet.port_number()}]
  def decode_packet(packet, source_ip, our_cookie) do
    with {:ok, %{port: port, hashes: hashes, cookie: cookie}} <- parse_message(packet),
         true <- cookie != our_cookie do
      Enum.map(hashes, &{&1, source_ip, port})
    else
      _ -> []
    end
  end

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

  @spec open_sockets(Acceptor.multicast_interfaces()) :: %{
          inet: :gen_udp.socket() | nil,
          inet6: :gen_udp.socket() | nil
        }
  defp open_sockets(interfaces) do
    %{
      inet: open_socket(:inet, interfaces.inet),
      inet6: open_socket(:inet6, interfaces.inet6)
    }
  end

  @spec refresh_interfaces(map()) :: map()
  defp refresh_interfaces(state) do
    interfaces = Acceptor.multicast_interfaces()

    needs_reopen =
      interfaces != state.interfaces or
        (interfaces.inet != [] and state.sockets.inet == nil) or
        (interfaces.inet6 != [] and state.sockets.inet6 == nil)

    if needs_reopen do
      close_sockets(state.sockets)
      %{state | interfaces: interfaces, sockets: open_sockets(interfaces)}
    else
      state
    end
  end

  @spec close_sockets(%{inet: :gen_udp.socket() | nil, inet6: :gen_udp.socket() | nil}) :: :ok
  defp close_sockets(sockets) do
    sockets
    |> Map.values()
    |> Enum.filter(&is_port/1)
    |> Enum.each(&:gen_udp.close/1)

    :ok
  end

  @spec open_socket(Acceptor.ip_family(), [:inet.ip4_address() | non_neg_integer()]) ::
          :gen_udp.socket() | nil
  defp open_socket(_family, []), do: nil

  defp open_socket(family, interfaces) do
    opts = [
      :binary,
      {:active, true},
      {:reuseaddr, true},
      {:reuseport, true},
      {:multicast_ttl, @multicast_ttl},
      # Loopback on so multiple BitTorrent processes on the same host can find
      # each other via LSD (libtorrent does the same). Our cookie filter drops
      # our own echoes.
      {:multicast_loop, true}
    ]

    opts = if family == :inet6, do: [:inet6, {:ipv6_v6only, true} | opts], else: opts

    case :gen_udp.open(@port, opts) do
      {:ok, socket} ->
        joined =
          Enum.count(interfaces, fn interface ->
            :inet.setopts(socket, [membership_option(family, interface)]) == :ok
          end)

        if joined > 0 do
          socket
        else
          :gen_udp.close(socket)
          nil
        end

      {:error, reason} ->
        Logger.warning(
          "[lsd] socket open failed family=#{family} port=#{@port} reason=#{inspect(reason)}"
        )

        nil
    end
  end

  @spec announce_next(map()) :: {:noreply, map()}
  defp announce_next(%{announce_queue: []} = state) do
    Process.send_after(self(), :announce, @interval_ms)
    {:noreply, state}
  end

  defp announce_next(%{announce_queue: [{offset_ms, hashes} | rest]} = state) do
    broadcast(state, hashes)

    {next_message, next_delay} =
      case rest do
        [{next_offset_ms, _hashes} | _] ->
          {:announce_next, next_offset_ms - offset_ms}

        [] ->
          {:announce, next_cycle_delay(offset_ms)}
      end

    Process.send_after(self(), next_message, next_delay)

    {:noreply, %{state | announce_queue: rest}}
  end

  @spec broadcast(map(), [Torrent.hash()]) :: :ok
  defp broadcast(%{sockets: sockets, interfaces: interfaces, cookie: cookie}, hashes) do
    port = Acceptor.port()

    sent =
      hashes
      |> announce_datagrams(port, cookie, interfaces)
      |> Enum.count(fn {family, interface, group, payload} ->
        socket = Map.fetch!(sockets, family)

        if is_port(socket) and
             :inet.setopts(socket, [{:multicast_if, interface}]) == :ok do
          :gen_udp.send(socket, group, @port, payload) == :ok
        else
          false
        end
      end)

    Logger.debug("[lsd] announced hashes=#{length(hashes)} datagrams=#{sent} port=#{port}")
    :ok
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
    packet
    |> decode_packet(source_ip, our_cookie)
    |> Enum.each(fn {hash, ip, port} -> offer_peer(hash, ip, port) end)

    :ok
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

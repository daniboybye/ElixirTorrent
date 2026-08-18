defmodule Acceptor do
  @moduledoc """
  Inbound peer acceptor: global IP cache, blacklist, TCP listener, and handshake workers.
  """

  alias __MODULE__.{BlackList, Connection, IpCache}
  alias Connection.{Handler, Handshakes}
  require Logger

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link, [[IpCache, BlackList, Connection], [strategy: :one_for_one]]}
    }
  end

  defdelegate port(), to: Handler

  defdelegate malicious_peer(id), to: BlackList, as: :put

  defdelegate handshakes(peers, hash), to: Handshakes

  @tcp_performance [nodelay: true, recbuf: 262_144, sndbuf: 262_144]
  @tcp_connect_fallback [nodelay: true]

  @spec socket_options() :: list()
  def socket_options, do: [:binary, active: false, reuseaddr: true]

  @spec tcp_socket_options() :: list()
  def tcp_socket_options, do: socket_options() ++ @tcp_performance

  @spec apply_tcp_performance(:gen_tcp.socket()) :: :ok
  def apply_tcp_performance(socket) when is_port(socket) do
    case :inet.setopts(socket, @tcp_performance) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("[acceptor] tcp_performance partial reason=#{inspect(reason)}")

        case :inet.setopts(socket, @tcp_connect_fallback) do
          :ok -> :ok
          {:error, _} -> :ok
        end
    end
  catch
    :exit, _ -> :ok
  end

  @spec socket_options(:inet | :inet6) :: list()
  def socket_options(:inet), do: socket_options() ++ [:inet]
  def socket_options(:inet6), do: socket_options() ++ [:inet6, ipv6_v6only: false]

  # ipv6_v6only is a bind/listen-time option; gen_tcp.connect rejects it with
  # badarg, which silently killed every outbound IPv6 TCP dial.
  @spec connect_options(:inet | :inet6) :: list()
  def connect_options(:inet), do: socket_options() ++ [:inet]
  def connect_options(:inet6), do: socket_options() ++ [:inet6]

  @spec tcp_socket_options(:inet | :inet6) :: list()
  def tcp_socket_options(:inet), do: tcp_socket_options() ++ [:inet]
  def tcp_socket_options(:inet6), do: tcp_socket_options() ++ [:inet6, ipv6_v6only: false]

  @spec port_range() :: Range.t()
  def port_range, do: 6881..9999

  @spec open_udp() :: {:ok, port()} | :error
  def open_udp, do: open_udp(:inet)

  # Request sockets (UDP trackers) bind an OS-chosen ephemeral port. Binding
  # into 6881..6889 attracts stray DHT/uTP traffic: some trackers hand out our
  # source port instead of the announced port field (BEP 15), so peers end up
  # dialing whatever short-lived socket sits there next.
  @spec open_udp(:inet | :inet6) :: {:ok, port()} | :error
  def open_udp(family), do: open_udp(family, nil)

  @spec open_udp(:inet | :inet6, :inet.ip_address() | nil) :: {:ok, port()} | :error
  def open_udp(family, bind_ip) do
    bind_opts = if bind_ip, do: [ip: bind_ip], else: []

    case :gen_udp.open(0, socket_options(family) ++ bind_opts) do
      {:ok, socket} ->
        {:ok, socket}

      # The caller only needs "no socket", but the reason is the only clue a
      # host-specific failure (a family the machine has switched off, a source
      # address that vanished between the getifaddrs snapshot and the bind)
      # ever leaves behind, and it is otherwise unrecoverable from a test
      # report on a machine we cannot attach to.
      {:error, reason} ->
        Logger.debug(
          "[acceptor] udp_open_failed family=#{family} bind=#{if bind_ip, do: format_ip(bind_ip), else: "any"} reason=#{inspect(reason)}"
        )

        :error
    end
  end

  @key :crypto.strong_rand_bytes(4)

  @spec key() :: <<_::32>>
  def key, do: @key

  @spec ip() :: tuple()
  def ip do
    :inet.getif()
    |> elem(1)
    |> hd()
    |> elem(0)
  end

  @type ip_family :: :inet | :inet6
  @type multicast_interfaces :: %{
          inet: [:inet.ip4_address()],
          inet6: [non_neg_integer()]
        }
  @type ip_snapshot :: %{
          inet: :inet.ip4_address() | nil,
          inet6: :inet.ip6_address() | nil,
          inet6_all: [:inet.ip6_address()],
          multicast_interfaces: multicast_interfaces()
        }

  # Cached snapshot of getifaddrs-derived addresses. Written by IpCache every
  # 30s; readers hit :persistent_term (~constant time), with a direct compute
  # fallback for the pre-boot / test path where IpCache is not running.
  @ip_cache_key {__MODULE__, :ip_cache}

  @doc false
  @spec ip_cache_key() :: term()
  def ip_cache_key, do: @ip_cache_key

  @spec primary_ips() :: %{inet: :inet.ip4_address() | nil, inet6: :inet.ip6_address() | nil}
  def primary_ips do
    %{inet: v4, inet6: v6} = all_global_ips()
    %{inet: v4, inet6: v6}
  end

  @doc false
  @spec all_global_ips() :: ip_snapshot()
  def all_global_ips do
    case :persistent_term.get(@ip_cache_key, nil) do
      nil -> compute_all_global_ips()
      cached -> cached
    end
  end

  @doc false
  @spec compute_all_global_ips() :: ip_snapshot()
  def compute_all_global_ips, do: compute_all_global_ips(:inet.getifaddrs())

  # Split from the getifaddrs call so the address-classification rules (which
  # decide what we may advertise to trackers, DHT and PEX) can be exercised
  # against a synthetic interface list instead of whatever this host happens to
  # be plugged into.
  @doc false
  @spec compute_all_global_ips({:ok, [{charlist(), keyword()}]} | {:error, term()}) ::
          ip_snapshot()
  def compute_all_global_ips({:ok, ifs}) do
    ips =
      ifs
      |> Enum.flat_map(fn {_ifname, props} ->
        props
        |> Keyword.get_values(:addr)
        |> Enum.filter(&is_tuple/1)
      end)

    v6_all = Enum.filter(ips, &global_ipv6?/1)

    %{
      inet: Enum.find(ips, &global_ipv4?/1),
      inet6: List.first(v6_all),
      inet6_all: v6_all,
      multicast_interfaces: multicast_interfaces_from(ifs)
    }
  end

  def compute_all_global_ips({:error, reason}) do
    Logger.warning("getifaddrs failed: #{inspect(reason)}")
    %{inet: nil, inet6: nil, inet6_all: [], multicast_interfaces: %{inet: [], inet6: []}}
  end

  @doc false
  @spec multicast_interfaces() :: multicast_interfaces()
  def multicast_interfaces, do: all_global_ips().multicast_interfaces

  @doc false
  @spec multicast_interfaces_from(
          [{charlist(), keyword()}],
          (charlist() -> {:ok, non_neg_integer()} | {:error, term()})
        ) :: multicast_interfaces()
  def multicast_interfaces_from(ifs, index_fun \\ &:net.if_name2index/1) do
    {v4, v6} =
      Enum.reduce(ifs, {[], []}, fn {ifname, props}, acc ->
        multicast_reduce_if(ifname, props, acc, index_fun)
      end)

    %{inet: Enum.uniq(v4), inet6: Enum.uniq(v6)}
  end

  defp multicast_reduce_if(ifname, props, {v4_acc, v6_acc}, index_fun) do
    flags = Keyword.get(props, :flags, [])
    addresses = Keyword.get_values(props, :addr)

    if multicast_eligible?(flags) do
      interface_v4 = Enum.filter(addresses, &multicast_ipv4?/1)
      interface_v6 = multicast_ipv6_indices(addresses, ifname, index_fun)
      {interface_v4 ++ v4_acc, interface_v6 ++ v6_acc}
    else
      {v4_acc, v6_acc}
    end
  end

  defp multicast_eligible?(flags) do
    :up in flags and :running in flags and :multicast in flags and
      :loopback not in flags and :pointtopoint not in flags
  end

  defp multicast_ipv6_indices(addresses, ifname, index_fun) do
    if Enum.any?(addresses, &multicast_ipv6?/1) do
      case index_fun.(ifname) do
        {:ok, index} -> [index]
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  @spec multicast_ipv4?(term()) :: boolean()
  defp multicast_ipv4?({a, _b, _c, _d}) when a in 1..126, do: true
  defp multicast_ipv4?({a, _b, _c, _d}) when a in 128..223, do: true
  defp multicast_ipv4?(_), do: false

  @spec multicast_ipv6?(term()) :: boolean()
  defp multicast_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp multicast_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp multicast_ipv6?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8})
       when is_integer(s1) and s1 not in 0xFF00..0xFFFF,
       do: true

  defp multicast_ipv6?(_), do: false

  @doc false
  @spec ipv6_binary(:inet.ip6_address()) :: <<_::128>>
  def ipv6_binary({s1, s2, s3, s4, s5, s6, s7, s8}) do
    <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>>
  end

  @spec global_ipv4?(:inet.ip_address()) :: boolean()
  defp global_ipv4?({a, _b, _c, _d} = ip) when is_integer(a) do
    case ip do
      {0, 0, 0, 0} -> false
      {127, _, _, _} -> false
      {169, 254, _, _} -> false
      {224, _, _, _} -> false
      {a, _, _, _} when a >= 240 -> false
      _ -> true
    end
  end

  defp global_ipv4?(_), do: false

  @spec global_ipv6?(:inet.ip_address()) :: boolean()
  defp global_ipv6?({s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8} = ip) when is_integer(s1) do
    case ip do
      {0, 0, 0, 0, 0, 0, 0, 0} -> false
      {0, 0, 0, 0, 0, 0, 0, 1} -> false
      _ when s1 in 0xFF00..0xFFFF -> false
      _ when s1 in 0xFE80..0xFEBF -> false
      _ -> true
    end
  end

  defp global_ipv6?(_), do: false

  @spec ip_binary() :: <<_::32>> | <<_::128>>
  def ip_binary do
    case ip() do
      {a, b, c, d} ->
        <<a, b, c, d>>

      {s1, s2, s3, s4, s5, s6, s7, s8} ->
        <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>>
    end
  end

  @doc """
  Whether an outbound packet to `ip` is permitted by the configured dial scope.

  `:elixir_torrent, :network, :dial_scope` is `:any` in production. `:test` sets
  `:this_host`, which permits only addresses this machine owns — loopback and
  the interface addresses the acceptor binds. Fixtures decoded from tracker/DHT/
  PEX payloads carry real addresses, and a test that drives a dial or answers a
  synthetic KRPC query would otherwise put a packet on the wire.

  This is a destination policy, not a protocol rule: peer *selection*
  (`Handshakes.connectable_peer?/2`) is unaffected, because PEX advertisement
  and hole-punch read it too.
  """
  @spec dial_scope_allows?(:inet.ip_address()) :: boolean()
  def dial_scope_allows?(ip) do
    case Keyword.get(Application.get_env(:elixir_torrent, :network, []), :dial_scope, :any) do
      :this_host -> this_host_ip?(ip)
      _ -> true
    end
  end

  @doc """
  Whether `ip` is a loopback address (`127.0.0.0/8` or `::1`).

  A loopback destination is reachable *only* from a loopback source. The route
  to it leaves through the loopback interface, and that interface owns no other
  address, so a socket bound to a LAN/global source address has no valid path to
  it. Windows enforces that (strong host model, the default since Vista) and
  fails the `connect`/`sendto` with `:eaddrnotavail`; macOS/BSD use the weak host
  model and quietly let the packet through with a foreign source address. The
  bind therefore has to be skipped for loopback destinations on every platform —
  see `ARCHITECTURE.md` § "Outbound source binding".
  """
  @spec loopback_ip?(:inet.ip_address()) :: boolean()
  def loopback_ip?({127, _, _, _}), do: true
  def loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback_ip?(_), do: false

  @doc """
  The local address the routing table picks for a packet aimed at `dest`.

  Asks the kernel instead of guessing: a UDP socket is opened, `connect`ed to
  the destination and `sockname`d. `connect/3` on a datagram socket only stores
  the peer and runs the route lookup that fixes the local address — **no packet
  is sent** — so this is a pure question to the routing table, cheap enough to
  ask per announce.

  Returns `nil` when the family is unavailable, when there is no route
  (`:enetunreach`/`:ehostunreach`), or when the stack answers with the
  unspecified address.
  """
  @spec route_source_ip(:inet.ip_address(), :inet.port_number()) :: :inet.ip_address() | nil
  def route_source_ip(dest, port) when tuple_size(dest) in [4, 8] do
    family = if tuple_size(dest) == 4, do: :inet, else: :inet6

    case :gen_udp.open(0, [:binary, family, {:active, false}]) do
      {:ok, socket} ->
        try do
          probe_route_source(socket, dest, probe_port(port))
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        Logger.debug(
          "[acceptor] route_probe_no_socket family=#{family} reason=#{inspect(reason)}"
        )

        nil
    end
  end

  @spec probe_route_source(port(), :inet.ip_address(), :inet.port_number()) ::
          :inet.ip_address() | nil
  defp probe_route_source(socket, dest, port) do
    with :ok <- :gen_udp.connect(socket, dest, port),
         {:ok, {local, _port}} <- :inet.sockname(socket) do
      if unspecified_ip?(local), do: nil, else: local
    else
      {:error, reason} ->
        Logger.debug(
          "[acceptor] route_probe_failed dest=#{format_ip(dest)} reason=#{inspect(reason)}"
        )

        nil
    end
  end

  # A datagram socket cannot be connected to port 0 (`:eaddrnotavail` on
  # macOS), and the port is irrelevant to the route lookup anyway.
  @spec probe_port(term()) :: :inet.port_number()
  defp probe_port(port) when is_integer(port) and port in 1..65_535, do: port
  defp probe_port(_port), do: 1

  @doc """
  The source address to bind for an announce to `dest`, given the address BEP 7
  would like us to advertise (`preferred`).

  BEP 7 wants the tracker to see the announce arrive *from* the address we are
  claiming, so the announce socket is bound to it. That bind is a promise the
  routing table has to keep: the packet must leave through an interface that
  owns the bound address. **Windows enforces this (strong host model) and fails
  the `connect`/`sendto` with `:eaddrnotavail`; macOS/BSD are weak-host and emit
  the packet with a source the outgoing interface does not own.** Picking the
  source from a *list* of our addresses (`all_global_ips/0`) therefore breaks
  every announce on Windows as soon as the machine is multi-homed — a VPN
  tunnel, a second NIC, or phone tethering.

  A `nil` destination means "not resolved here" (the HTTP path lets Hackney do
  its own DNS); there is nothing to route against, so the BEP 7 bind is kept.
  """
  @spec announce_source_ip(
          :inet.ip_address() | nil,
          :inet.port_number(),
          :inet.ip_address() | nil
        ) :: :inet.ip_address() | nil
  def announce_source_ip(nil, _port, preferred), do: preferred

  def announce_source_ip(_dest, _port, nil), do: nil

  def announce_source_ip(dest, port, preferred) do
    if loopback_ip?(dest) do
      nil
    else
      case route_source_ip(dest, port) do
        # The common single-homed case: the stack would use exactly the address
        # we want to announce. No getifaddrs walk needed.
        ^preferred -> preferred
        route_source -> select_source_ip(dest, preferred, route_source, :inet.getifaddrs())
      end
    end
  end

  @doc false
  @spec select_source_ip(
          :inet.ip_address(),
          :inet.ip_address() | nil,
          :inet.ip_address() | nil,
          {:ok, [{charlist(), keyword()}]} | {:error, term()}
        ) :: :inet.ip_address() | nil
  def select_source_ip(dest, preferred, route_source, ifaddrs) do
    cond do
      # Loopback leaves through an interface that owns no global address.
      loopback_ip?(dest) ->
        nil

      # Nothing to promise for this family, or a preference of the wrong
      # family: let the stack choose and announce whatever it uses.
      preferred == nil or not same_family?(dest, preferred) ->
        nil

      # The route lookup told us nothing (no route, or no socket of that
      # family). Keep the BEP 7 bind rather than silently dropping it; the
      # announce is already in trouble, and `Tracker` retries unbound if the
      # bind is what the stack rejects.
      route_source == nil ->
        preferred

      # The stack would use the address we want anyway.
      route_source == preferred ->
        preferred

      # A different address on the *same* interface. The strong host model is
      # satisfied — the interface that routes to `dest` owns `preferred` — and
      # BEP 7's choice survives. This is the normal IPv6 case: RFC 6724 source
      # selection prefers a temporary/privacy address, while we announce (and
      # derive our BEP 42 DHT node id from) the address `all_global_ips/0`
      # picked. Binding keeps both consistent.
      same_interface?(ifaddrs, preferred, route_source) ->
        preferred

      # `preferred` lives on an interface that does not route to `dest` — VPN
      # tunnel up, second NIC, tethering. Announce the address the route
      # actually uses; it is a global address, so BEP 7 still holds, and it is
      # the address the tracker would record for us in any case.
      global_ip?(route_source) ->
        route_source

      # The route leaves from something we would never advertise (link-local,
      # or a loopback source for a non-loopback destination). Bind nothing.
      true ->
        nil
    end
  end

  @spec same_family?(:inet.ip_address(), :inet.ip_address()) :: boolean()
  defp same_family?(a, b) when is_tuple(a) and is_tuple(b),
    do: tuple_size(a) == tuple_size(b)

  defp same_family?(_a, _b), do: false

  # Two addresses share an interface when one `getifaddrs` entry lists both.
  @spec same_interface?(
          {:ok, [{charlist(), keyword()}]} | {:error, term()},
          :inet.ip_address(),
          :inet.ip_address()
        ) :: boolean()
  defp same_interface?({:ok, ifs}, a, b) do
    Enum.any?(ifs, fn {_ifname, props} ->
      addresses = Keyword.get_values(props, :addr)
      a in addresses and b in addresses
    end)
  end

  defp same_interface?(_ifaddrs, _a, _b), do: false

  @spec unspecified_ip?(:inet.ip_address()) :: boolean()
  defp unspecified_ip?({0, 0, 0, 0}), do: true
  defp unspecified_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp unspecified_ip?(_), do: false

  @spec global_ip?(term()) :: boolean()
  defp global_ip?({_a, _b, _c, _d} = ip), do: global_ipv4?(ip)
  defp global_ip?({_s1, _s2, _s3, _s4, _s5, _s6, _s7, _s8} = ip), do: global_ipv6?(ip)
  defp global_ip?(_ip), do: false

  @spec this_host_ip?(:inet.ip_address()) :: boolean()
  defp this_host_ip?({127, _, _, _}), do: true
  defp this_host_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp this_host_ip?(ip) do
    %{inet: v4, inet6_all: v6_all} = all_global_ips()
    ip == v4 or ip in v6_all
  end

  @doc false
  @spec ipv4_binary() :: <<_::32>> | nil
  def ipv4_binary do
    case primary_ips().inet do
      {a, b, c, d} -> <<a, b, c, d>>
      _ -> nil
    end
  end

  @doc false
  @spec ipv6_binary() :: <<_::128>> | nil
  def ipv6_binary do
    case primary_ips().inet6 do
      ip when is_tuple(ip) -> ipv6_binary(ip)
      _ -> nil
    end
  end

  @doc false
  @spec announcable_ipv6() :: [:inet.ip6_address()]
  def announcable_ipv6 do
    case all_global_ips() do
      %{inet6: nil} -> []
      %{inet6: ip} -> [ip]
    end
  end

  @doc false
  @spec format_ip(:inet.ip_address()) :: String.t()
  def format_ip(ip) do
    ip
    |> :inet.ntoa()
    |> List.to_string()
  end
end

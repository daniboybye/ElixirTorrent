defmodule Acceptor do
  alias __MODULE__.{BlackList, Connection}
  alias Connection.{Handshakes, Handler}
  require Logger

  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [[BlackList, Connection], [strategy: :one_for_one]]}
    }
  end

  defdelegate port(), to: Handler

  defdelegate malicious_peer(id), to: BlackList, as: :put

  defdelegate handshakes(peers, hash), to: Handshakes

  @tcp_performance [nodelay: true, recbuf: 262_144, sndbuf: 262_144]
  @tcp_connect_fallback [nodelay: true]

  @spec socket_options() :: list()
  def socket_options(), do: [:binary, active: false, reuseaddr: true]

  @spec tcp_socket_options() :: list()
  def tcp_socket_options(), do: socket_options() ++ @tcp_performance

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

  @spec tcp_socket_options(:inet | :inet6) :: list()
  def tcp_socket_options(:inet), do: tcp_socket_options() ++ [:inet]
  def tcp_socket_options(:inet6), do: tcp_socket_options() ++ [:inet6, ipv6_v6only: false]

  @spec port_range() :: Range.t()
  def port_range(), do: 6881..9999

  @spec open_udp() :: {:ok, port()} | :error
  def open_udp(), do: open_udp(:inet)

  @spec open_udp(:inet | :inet6) :: {:ok, port()} | :error
  def open_udp(family) do
    Enum.find_value(port_range(), :error, fn number ->
      with {:error, _} <- :gen_udp.open(number, socket_options(family)),
           do: nil
    end)
  end

  @key :crypto.strong_rand_bytes(4)

  @spec key() :: <<_::32>>
  def key(), do: @key

  @spec ip() :: tuple()
  def ip() do
    :inet.getif()
    |> elem(1)
    |> hd()
    |> elem(0)
  end

  @type ip_family :: :inet | :inet6

  @spec primary_ips() :: %{inet: :inet.ip4_address() | nil, inet6: :inet.ip6_address() | nil}
  def primary_ips() do
    # Minimal multi-homed support: pick one "best" IPv4 and one "best" IPv6 address.
    # BEP 7 full support would announce *each* local address we intend to listen on.
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        ips =
          ifs
          |> Enum.flat_map(fn {_ifname, props} ->
            props
            |> Keyword.get_values(:addr)
            |> Enum.filter(&is_tuple/1)
          end)

        %{
          inet: Enum.find(ips, &global_ipv4?/1),
          inet6: Enum.find(ips, &global_ipv6?/1)
        }

      {:error, reason} ->
        Logger.warning("getifaddrs failed: #{inspect(reason)}")
        %{inet: nil, inet6: nil}
    end
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
  def ip_binary() do
    case ip() do
      {a, b, c, d} ->
        <<a, b, c, d>>

      {s1, s2, s3, s4, s5, s6, s7, s8} ->
        <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>>
    end
  end
end

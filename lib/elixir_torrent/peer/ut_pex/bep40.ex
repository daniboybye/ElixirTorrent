defmodule Peer.UtPex.BEP40 do
  @moduledoc """
  BEP 40 canonical peer priority (CRC32C over sorted masked addresses).

  Client and peer must be the same address family; mixed-family comparisons return `:error`.
  """

  alias Peer.UtPex.CRC32C

  @type client :: {:inet.ip_address(), :inet.port_number()}
  @type peer :: client()

  @doc false
  @spec priority(client(), peer()) :: {:ok, non_neg_integer()} | :error
  def priority(client, peer) do
    with {:ok, bytes} <- priority_bytes(client, peer) do
      {:ok, CRC32C.checksum(bytes)}
    end
  end

  @doc false
  @spec priority_bytes(client(), peer()) :: {:ok, binary()} | :error
  def priority_bytes({client_ip, client_port}, {peer_ip, peer_port}) do
    cond do
      same_ip?(client_ip, peer_ip) ->
        {:ok, sort_ports(client_port, peer_port)}

      v4?(client_ip) and v4?(peer_ip) ->
        mask = ipv4_mask(client_ip, peer_ip)
        a = mask_ip4(client_ip, mask)
        b = mask_ip4(peer_ip, mask)
        {:ok, sort_pair(a, b)}

      v6?(client_ip) and v6?(peer_ip) ->
        mask_bytes = ipv6_mask_bytes(client_ip, peer_ip)
        a = mask_ip6(client_ip, mask_bytes)
        b = mask_ip6(peer_ip, mask_bytes)
        {:ok, sort_pair(a, b)}

      true ->
        :error
    end
  end

  @doc false
  @spec sort_peers(client(), [peer()], keyword()) :: [peer()]
  def sort_peers(client, peers, opts \\ []) when is_list(peers) do
    tie = Keyword.get(opts, :tie_breaker, :endpoint)

    peers
    |> Enum.sort_by(
      fn peer ->
        tie_key =
          case tie do
            :endpoint -> peer
            :port -> elem(peer, 1)
            _ -> peer
          end

        case priority(client, peer) do
          {:ok, priority} -> {0, Bitwise.bxor(priority, 0xFFFFFFFF), tie_key}
          :error -> {1, 0, tie_key}
        end
      end,
      &<=/2
    )
  end

  @spec sort_pair(binary(), binary()) :: binary()
  defp sort_pair(a, b) do
    if a > b, do: b <> a, else: a <> b
  end

  @spec sort_ports(:inet.port_number(), :inet.port_number()) :: binary()
  defp sort_ports(p1, p2) when p1 > p2, do: <<p2::16, p1::16>>
  defp sort_ports(p1, p2), do: <<p1::16, p2::16>>

  @spec v4?(:inet.ip_address()) :: boolean()
  defp v4?({_, _, _, _}), do: true
  defp v4?(_), do: false

  @spec v6?(:inet.ip_address()) :: boolean()
  defp v6?({_, _, _, _, _, _, _, _}), do: true
  defp v6?(_), do: false

  @spec same_ip?(:inet.ip_address(), :inet.ip_address()) :: boolean()
  defp same_ip?(a, b), do: a == b

  @spec ipv4_mask(:inet.ip_address(), :inet.ip_address()) :: {byte(), byte(), byte(), byte()}
  defp ipv4_mask(a, b) do
    cond do
      not same_subnet_v4?(a, b, 16) -> {0xFF, 0xFF, 0x55, 0x55}
      not same_subnet_v4?(a, b, 24) -> {0xFF, 0xFF, 0xFF, 0x55}
      true -> {0xFF, 0xFF, 0xFF, 0xFF}
    end
  end

  @spec ipv6_mask_bytes(:inet.ip_address(), :inet.ip_address()) :: pos_integer()
  defp ipv6_mask_bytes(a, b) do
    a = ip6_binary(a)
    b = ip6_binary(b)

    Enum.find(6..15, 16, fn bytes ->
      binary_part(a, 0, bytes) != binary_part(b, 0, bytes)
    end)
  end

  @spec mask_ip4(:inet.ip_address(), {byte(), byte(), byte(), byte()}) :: binary()
  defp mask_ip4({a, b, c, d}, {m0, m1, m2, m3}),
    do: <<Bitwise.band(a, m0), Bitwise.band(b, m1), Bitwise.band(c, m2), Bitwise.band(d, m3)>>

  @spec mask_ip6(:inet.ip_address(), pos_integer()) :: binary()
  defp mask_ip6(ip, unmasked_bytes) do
    ip
    |> ip6_binary()
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} ->
      Bitwise.band(byte, if(index < unmasked_bytes, do: 0xFF, else: 0x55))
    end)
    |> :binary.list_to_bin()
  end

  @spec same_subnet_v4?(:inet.ip_address(), :inet.ip_address(), pos_integer()) :: boolean()
  defp same_subnet_v4?({a1, b1, c1, _d1}, {a2, b2, c2, _d2}, bits) do
    case bits do
      16 -> a1 == a2 and b1 == b2
      24 -> a1 == a2 and b1 == b2 and c1 == c2
      _ -> false
    end
  end

  @spec ip6_binary(:inet.ip_address()) :: binary()
  defp ip6_binary({s1, s2, s3, s4, s5, s6, s7, s8}),
    do: <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>>
end

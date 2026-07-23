defmodule DHT.Compact do
  @moduledoc """
  BEP 5 § Contact Encoding — compact node info (26 bytes) and compact peer info (6 bytes).

  Compact node info: 20-byte node id + 4-byte IPv4 + 2-byte port (network byte order).
  Compact peer info: 4-byte IPv4 + 2-byte port (BEP 23 IPv4 compact peers).
  """

  @node_info_size 26
  @node_info6_size 38
  @peer_info_size 6
  @ipv6_peer_info_size 18

  @type node_id :: <<_::160>>
  @type contact :: %{
          id: node_id(),
          ip: :inet.ip_address(),
          port: :inet.port_number()
        }

  @doc "BEP 5 § Contact Encoding — encode one compact node info entry (26 bytes)."
  @spec encode_node(node_id(), :inet.ip_address(), :inet.port_number()) ::
          <<_::208>> | {:error, :unsupported_ip}
  def encode_node(id, {a, b, c, d}, port)
      when byte_size(id) == 20 and is_integer(port) and port in 1..65535 do
    <<id::binary-size(20), a, b, c, d, port::16>>
  end

  def encode_node(_id, _ip, _port), do: {:error, :unsupported_ip}

  @doc "BEP 5 § Contact Encoding — encode a list of nodes into a compact node info string."
  @spec encode_nodes([contact()]) :: binary()
  def encode_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce(<<>>, fn %{id: id, ip: ip, port: port}, acc ->
      case encode_node(id, ip, port) do
        entry when is_binary(entry) -> acc <> entry
        _ -> acc
      end
    end)
  end

  @doc "BEP 5 § Contact Encoding — decode compact node info (multiples of 26 bytes)."
  @spec decode_nodes(binary()) :: [contact()]
  def decode_nodes(binary) when is_binary(binary) do
    decode_nodes(binary, [])
  end

  defp decode_nodes(<<id::binary-size(20), a, b, c, d, port::16, rest::binary>>, acc) do
    decode_nodes(rest, [%{id: id, ip: {a, b, c, d}, port: port} | acc])
  end

  defp decode_nodes(_rest, acc), do: Enum.reverse(acc)

  @doc "BEP 23 § compact peers — encode one IPv4 peer (6 bytes)."
  @spec encode_peer(:inet.ip_address(), :inet.port_number()) ::
          <<_::48>> | {:error, :unsupported_ip}
  def encode_peer({a, b, c, d}, port)
      when is_integer(port) and port in 1..65535 do
    <<a, b, c, d, port::16>>
  end

  def encode_peer(_ip, _port), do: {:error, :unsupported_ip}

  @doc "BEP 23 § compact peers — decode compact peer info (multiples of 6 bytes)."
  @spec decode_peers(binary()) :: [Peer.t()]
  def decode_peers(binary) when is_binary(binary) do
    decode_peers(binary, [])
  end

  defp decode_peers(<<a, b, c, d, port::16, rest::binary>>, acc) do
    decode_peers(rest, [%Peer{ip: {a, b, c, d}, port: port} | acc])
  end

  defp decode_peers(_rest, acc), do: Enum.reverse(acc)

  @doc "BEP 32 § compact peer info — encode one IPv6 peer (18 bytes)."
  @spec encode_ipv6_peer(:inet.ip_address(), :inet.port_number()) ::
          <<_::144>> | {:error, :unsupported_ip}
  def encode_ipv6_peer({s1, s2, s3, s4, s5, s6, s7, s8}, port)
      when is_integer(port) and port in 1..65535 do
    <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16, port::16>>
  end

  def encode_ipv6_peer(_ip, _port), do: {:error, :unsupported_ip}

  @doc "BEP 32 § compact peer info — decode IPv6 peers (multiples of 18 bytes)."
  @spec decode_ipv6_peers(binary()) :: [Peer.t()]
  def decode_ipv6_peers(binary) when is_binary(binary) do
    decode_ipv6_peers(binary, [])
  end

  defp decode_ipv6_peers(
         <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16, port::16,
           rest::binary>>,
         acc
       ) do
    decode_ipv6_peers(rest, [%Peer{ip: {s1, s2, s3, s4, s5, s6, s7, s8}, port: port} | acc])
  end

  defp decode_ipv6_peers(_rest, acc), do: Enum.reverse(acc)

  @doc "BEP 32 § contact encoding — decode compact IPv6 node info (multiples of 38 bytes)."
  @spec decode_nodes6(binary()) :: [contact()]
  def decode_nodes6(binary) when is_binary(binary) do
    decode_nodes6(binary, [])
  end

  defp decode_nodes6(
         <<id::binary-size(20), s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16,
           port::16, rest::binary>>,
         acc
       ) do
    decode_nodes6(rest, [%{id: id, ip: {s1, s2, s3, s4, s5, s6, s7, s8}, port: port} | acc])
  end

  defp decode_nodes6(_rest, acc), do: Enum.reverse(acc)

  @doc "BEP 32 § contact encoding — encode one compact IPv6 node info entry (38 bytes)."
  @spec encode_node6(node_id(), :inet.ip_address(), :inet.port_number()) ::
          <<_::304>> | {:error, :unsupported_ip}
  def encode_node6(id, {s1, s2, s3, s4, s5, s6, s7, s8}, port)
      when byte_size(id) == 20 and is_integer(port) and port in 1..65535 do
    <<id::binary-size(20), s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16,
      port::16>>
  end

  def encode_node6(_id, _ip, _port), do: {:error, :unsupported_ip}

  @doc "BEP 32 § contact encoding — encode a list of IPv6 nodes into a compact node info string."
  @spec encode_nodes6([contact()]) :: binary()
  def encode_nodes6(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce(<<>>, fn %{id: id, ip: ip, port: port}, acc ->
      case encode_node6(id, ip, port) do
        entry when is_binary(entry) -> acc <> entry
        _ -> acc
      end
    end)
  end

  @doc false
  @spec node_info6_size() :: pos_integer()
  def node_info6_size, do: @node_info6_size

  @doc false
  @spec ipv6_peer_info_size() :: pos_integer()
  def ipv6_peer_info_size, do: @ipv6_peer_info_size

  @doc false
  @spec node_info_size() :: pos_integer()
  def node_info_size, do: @node_info_size

  @doc false
  @spec peer_info_size() :: pos_integer()
  def peer_info_size, do: @peer_info_size
end

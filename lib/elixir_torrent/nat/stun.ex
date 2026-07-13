defmodule NAT.Stun do
  @moduledoc """
  Minimal STUN client (RFC 5389) for NAT mapping-behaviour detection.

  BitTorrent has no STUN BEP, but STUN is the standard way to learn our
  server-reflexive (external) transport address and, crucially, to classify the
  NAT's *mapping behaviour* (RFC 5780):

    * send a Binding Request to several STUN servers from ONE local UDP socket;
    * if every server reports the SAME external port -> endpoint-independent
      mapping (a "cone" NAT); UDP/uTP hole punching (BEP 55) is viable;
    * if the external port DIFFERS per server -> endpoint-dependent mapping
      (a "symmetric" NAT); the external port can't be predicted, so IPv4 hole
      punching is infeasible and IPv6 is the only reachable inbound path.

  Under CGNAT this is the deciding measurement for whether investing further in
  BEP 55 for IPv4 is worthwhile. The mapping behaviour is a property of the NAT,
  so a fresh probe socket is representative of the listen socket's fate.
  """

  import Bitwise

  @magic_cookie 0x2112A442
  @binding_request 0x0001
  @binding_success 0x0101
  @attr_mapped_address 0x0001
  @attr_xor_mapped_address 0x0020
  @recv_timeout_ms 3_000

  # Diverse operators so the destination IPs genuinely differ — that is what
  # makes the endpoint-independent/-dependent comparison meaningful.
  @servers [
    {~c"stun.l.google.com", 19_302},
    {~c"stun.cloudflare.com", 3_478},
    {~c"stun.nextcloud.com", 443}
  ]

  @type reflexive :: {:inet.ip4_address(), :inet.port_number()}
  @type mapping :: :endpoint_independent | :endpoint_dependent | :unknown

  @mapping_key {__MODULE__, :mapping}

  @doc """
  The last classified NAT mapping behaviour, or `:unknown` before detection.

  Read by the hole-punch initiator to decide whether initiating is worthwhile:
  under `:endpoint_dependent` (symmetric) mapping our external port can't be
  predicted, so a punched peer can't reach us and initiating is futile.
  """
  @spec mapping() :: mapping()
  def mapping, do: :persistent_term.get(@mapping_key, :unknown)

  @doc false
  @spec put_mapping(mapping()) :: :ok
  def put_mapping(mapping) when mapping in [:endpoint_independent, :endpoint_dependent, :unknown] do
    :persistent_term.put(@mapping_key, mapping)
  end

  @doc """
  Probe the given STUN servers from a single UDP socket and classify the NAT's
  mapping behaviour. Returns the classification plus every reflexive address we
  managed to observe.
  """
  @spec detect([{charlist(), :inet.port_number()}]) ::
          {:ok, mapping(), [reflexive()]} | {:error, term()}
  def detect(servers \\ @servers) do
    case :gen_udp.open(0, [:binary, :inet, active: false]) do
      {:ok, socket} ->
        try do
          reflexives =
            servers
            |> Enum.map(fn {host, port} -> query(socket, host, port) end)
            |> Enum.flat_map(fn
              {:ok, addr} -> [addr]
              {:error, _} -> []
            end)

          {:ok, classify(reflexives), reflexives}
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Classify a list of observed reflexive addresses. Needs at least two successful
  observations; identical ports mean endpoint-independent mapping.
  """
  @spec classify([reflexive()]) :: mapping()
  def classify(reflexives) do
    ports = reflexives |> Enum.map(fn {_ip, port} -> port end) |> Enum.uniq()

    cond do
      length(reflexives) < 2 -> :unknown
      length(ports) == 1 -> :endpoint_independent
      true -> :endpoint_dependent
    end
  end

  @spec query(:gen_udp.socket(), charlist(), :inet.port_number()) ::
          {:ok, reflexive()} | {:error, term()}
  defp query(socket, host, port) do
    with {:ok, ip} <- :inet.getaddr(host, :inet),
         txid <- :crypto.strong_rand_bytes(12),
         :ok <- :gen_udp.send(socket, ip, port, encode_request(txid)),
         {:ok, {_from_ip, _from_port, resp}} <- :gen_udp.recv(socket, 0, @recv_timeout_ms) do
      decode_reflexive(resp, txid)
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc false
  @spec encode_request(binary()) :: binary()
  def encode_request(txid) when byte_size(txid) == 12 do
    <<@binding_request::16, 0::16, @magic_cookie::32, txid::binary>>
  end

  @doc false
  @spec decode_reflexive(binary(), binary()) :: {:ok, reflexive()} | {:error, term()}
  def decode_reflexive(
        <<@binding_success::16, len::16, @magic_cookie::32, txid::binary-size(12), attrs::binary>>,
        txid
      )
      when byte_size(attrs) >= len do
    case parse_attrs(binary_part(attrs, 0, len), nil) do
      nil -> {:error, :no_mapped_address}
      addr -> {:ok, addr}
    end
  end

  def decode_reflexive(_, _), do: {:error, :bad_response}

  # Walk the TLV attribute list. Prefer XOR-MAPPED-ADDRESS (RFC 5389); keep a
  # plain MAPPED-ADDRESS as a fallback for legacy servers.
  @spec parse_attrs(binary(), reflexive() | nil) :: reflexive() | nil
  defp parse_attrs(<<type::16, len::16, rest::binary>>, fallback) when byte_size(rest) >= len do
    value = binary_part(rest, 0, len)
    padded = len + rem(4 - rem(len, 4), 4)

    tail =
      if byte_size(rest) >= padded,
        do: binary_part(rest, padded, byte_size(rest) - padded),
        else: <<>>

    case type do
      @attr_xor_mapped_address ->
        case decode_xor_mapped(value) do
          {:ok, addr} -> addr
          _ -> parse_attrs(tail, fallback)
        end

      @attr_mapped_address ->
        fallback =
          case decode_mapped(value) do
            {:ok, addr} -> addr
            _ -> fallback
          end

        parse_attrs(tail, fallback)

      _ ->
        parse_attrs(tail, fallback)
    end
  end

  defp parse_attrs(_, fallback), do: fallback

  # XOR-MAPPED-ADDRESS: port XORed with the top 16 bits of the magic cookie,
  # IPv4 address XORed with the full 32-bit magic cookie.
  @spec decode_xor_mapped(binary()) :: {:ok, reflexive()} | {:error, :unsupported_family}
  defp decode_xor_mapped(<<0, 0x01, xport::16, xaddr::32>>) do
    port = bxor(xport, 0x2112)
    <<a, b, c, d>> = <<bxor(xaddr, @magic_cookie)::32>>
    {:ok, {{a, b, c, d}, port}}
  end

  defp decode_xor_mapped(_), do: {:error, :unsupported_family}

  @spec decode_mapped(binary()) :: {:ok, reflexive()} | {:error, :unsupported_family}
  defp decode_mapped(<<0, 0x01, port::16, a, b, c, d>>), do: {:ok, {{a, b, c, d}, port}}
  defp decode_mapped(_), do: {:error, :unsupported_family}
end

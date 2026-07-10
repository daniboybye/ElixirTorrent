defmodule Peer.UtPex do
  @moduledoc """
  BEP 11 Peer Exchange (`ut_pex`) — decode, encode, ingest, and broadcast.

  Wire format follows libtorrent / webtorrent: a bencoded dictionary with compact
  peer blobs in `added`, `added6`, `dropped`, and `dropped6` (optional `*.f` flags).
  """

  alias Tracker.UDP

  @extension_name "ut_pex"

  @type endpoint :: {:inet.ip_address(), :inet.port_number()}

  @doc false
  @spec extension_name() :: String.t()
  def extension_name, do: @extension_name

  @doc """
  Decodes an inbound ut_pex payload and dials any new connectable peers.
  """
  @spec ingest(Torrent.hash(), binary()) :: :ok
  def ingest(hash, payload) when is_binary(payload) do
    case decode(payload) do
      {:ok, added, _dropped} ->
        peers =
          added
          |> Enum.map(&%Peer{ip: elem(&1, 0), port: elem(&1, 1)})
          |> Enum.filter(&Acceptor.Connection.Handshakes.connectable_peer?/1)

        if peers != [] do
          require Logger

          Logger.info(
            "[ut_pex] ingest hash=#{Torrent.hex_encoded_hash(hash)} added=#{length(peers)}"
          )

          Acceptor.handshakes(peers, hash)
        end

        :ok

      :error ->
        :ok
    end
  end

  @doc """
  Sends a ut_pex delta to every connected peer that advertises `ut_pex`.
  """
  @spec broadcast(Torrent.hash(), [endpoint()], [endpoint()]) :: :ok
  def broadcast(hash, added, dropped) do
    payload = encode(added, dropped)

    if payload != nil do
      hash
      |> Torrent.Swarm.peer_supervisors()
      |> Enum.each(&Peer.send_pex(&1, payload))
    end

    :ok
  end

  @doc false
  @spec encode([endpoint()], [endpoint()]) :: binary() | nil
  def encode(added, dropped) do
    {added4, added6} = split_endpoints(added)
    {dropped4, dropped6} = split_endpoints(dropped)

    fields =
      []
      |> maybe_put("added", encode_ipv4(added4))
      |> maybe_put("added.f", flags(added4))
      |> maybe_put("added6", encode_ipv6(added6))
      |> maybe_put("added6.f", flags(added6))
      |> maybe_put("dropped", encode_ipv4(dropped4))
      |> maybe_put("dropped6", encode_ipv6(dropped6))

    case fields do
      [] -> nil
      _ -> Bento.encode!(Map.new(fields))
    end
  end

  @doc false
  @spec decode(binary()) :: {:ok, [endpoint()], [endpoint()]} | :error
  def decode(payload) when is_binary(payload) do
    case Bento.decode(payload) do
      {:ok, dict} when is_map(dict) ->
        added =
          decode_ipv4(Map.get(dict, "added", <<>>)) ++
            decode_ipv6(Map.get(dict, "added6", <<>>))

        dropped =
          decode_ipv4(Map.get(dict, "dropped", <<>>)) ++
            decode_ipv6(Map.get(dict, "dropped6", <<>>))

        {:ok, added, dropped}

      _ ->
        :error
    end
  end

  @spec split_endpoints([endpoint()]) :: {[endpoint()], [endpoint()]}
  defp split_endpoints(endpoints) do
    Enum.split_with(endpoints, fn {ip, _} -> tuple_size(ip) == 4 end)
  end

  @spec encode_ipv4([endpoint()]) :: binary()
  defp encode_ipv4(endpoints) do
    Enum.reduce(endpoints, <<>>, fn
      {{a, b, c, d}, port}, acc -> acc <> <<a, b, c, d, port::16>>
      _, acc -> acc
    end)
  end

  @spec encode_ipv6([endpoint()]) :: binary()
  defp encode_ipv6(endpoints) do
    Enum.reduce(endpoints, <<>>, fn
      {{s1, s2, s3, s4, s5, s6, s7, s8}, port}, acc ->
        acc <> <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16, port::16>>

      _, acc ->
        acc
    end)
  end

  @spec decode_ipv4(binary()) :: [endpoint()]
  defp decode_ipv4(bin) when is_binary(bin) do
    bin
    |> UDP.parse_compact_peers(:inet)
    |> Enum.map(&{&1.ip, &1.port})
  end

  @spec decode_ipv6(binary()) :: [endpoint()]
  defp decode_ipv6(bin) when is_binary(bin) do
    bin
    |> UDP.parse_compact_peers(:inet6)
    |> Enum.map(&{&1.ip, &1.port})
  end

  @spec flags([endpoint()]) :: binary()
  defp flags(endpoints), do: :binary.copy(<<0>>, length(endpoints))

  @spec maybe_put(keyword(), String.t(), binary()) :: keyword()
  defp maybe_put(fields, _key, <<>>), do: fields

  defp maybe_put(fields, key, value) when is_binary(value), do: [{key, value} | fields]
end

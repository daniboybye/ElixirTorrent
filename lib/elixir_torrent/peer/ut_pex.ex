defmodule Peer.UtPex do
  @moduledoc """
  BEP 11 Peer Exchange (`ut_pex`) — decode, encode, ingest, and broadcast.

  Wire format follows libtorrent / webtorrent: a bencoded dictionary with compact
  peer blobs in `added`, `added6`, `dropped`, and `dropped6` (optional `*.f` flags).
  """

  alias Tracker.UDP

  @extension_name "ut_pex"

  # BEP 11 per-peer flag bits in `added.f` / `added6.f` (one byte per compact peer):
  # 0x01 encrypted, 0x02 seed, 0x04 utp, 0x08 holepunch, 0x10 outgoing (reachability).
  @flag_seed 0x02

  @type endpoint :: {:inet.ip_address(), :inet.port_number()}

  @doc false
  @spec extension_name() :: String.t()
  def extension_name, do: @extension_name

  @doc """
  Decodes an inbound ut_pex payload and dials any new connectable peers.

  BEP 11 seed-flagged peers (`added.f` bit `@flag_seed`) are offered for dial before
  non-seeds so we prefer seeders when peer slots are scarce (CGNAT outbound dials).
  """
  @spec ingest(Torrent.hash(), binary()) :: :ok
  def ingest(hash, payload) when is_binary(payload) do
    case decode(payload) do
      {:ok, added, _dropped} ->
        peers =
          added
          |> prioritize_seed_peers()
          |> Enum.filter(&Acceptor.Connection.Handshakes.connectable_peer?/1)

        if peers != [] do
          require Logger

          seed_count = Enum.count(peers, &(&1.seed == true))

          Logger.info(
            "[ut_pex] ingest hash=#{Torrent.hex_encoded_hash(hash)} added=#{length(peers)} seeds=#{seed_count}"
          )

          Acceptor.handshakes(peers, hash)
        end

        :ok

      :error ->
        :ok
    end
  end

  @doc false
  @spec prioritize_seed_peers([Peer.t()]) :: [Peer.t()]
  def prioritize_seed_peers(peers) when is_list(peers) do
    Enum.sort_by(peers, fn %Peer{seed: seed} -> seed != true end)
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
  @spec decode(binary()) :: {:ok, [Peer.t()], [Peer.t()]} | :error
  def decode(payload) when is_binary(payload) do
    case Bento.decode(payload) do
      {:ok, dict} when is_map(dict) ->
        added =
          decode_peers_with_flags(
            Map.get(dict, "added", <<>>),
            Map.get(dict, "added.f"),
            :inet
          ) ++
            decode_peers_with_flags(
              Map.get(dict, "added6", <<>>),
              Map.get(dict, "added6.f"),
              :inet6
            )

        dropped =
          decode_peers_without_flags(Map.get(dict, "dropped", <<>>), :inet) ++
            decode_peers_without_flags(Map.get(dict, "dropped6", <<>>), :inet6)

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

  @spec decode_peers_with_flags(binary(), binary() | nil, :inet | :inet6) :: [Peer.t()]
  defp decode_peers_with_flags(<<>>, _flags_bin, _family), do: []

  defp decode_peers_with_flags(compact, flags_bin, family) do
    has_flags? = is_binary(flags_bin) and flags_bin != <<>>

    compact
    |> UDP.parse_compact_peers(family)
    |> Enum.with_index()
    |> Enum.map(fn {peer, idx} ->
      flag = if has_flags?, do: flags_byte(flags_bin, idx), else: 0

      seed =
        if has_flags? do
          Bitwise.band(flag, @flag_seed) != 0
        end

      %Peer{ip: peer.ip, port: peer.port, seed: seed}
    end)
  end

  @spec decode_peers_without_flags(binary(), :inet | :inet6) :: [Peer.t()]
  defp decode_peers_without_flags(<<>>, _family), do: []

  defp decode_peers_without_flags(compact, family) do
    compact
    |> UDP.parse_compact_peers(family)
    |> Enum.map(fn peer -> %Peer{ip: peer.ip, port: peer.port} end)
  end

  @spec flags_byte(binary(), non_neg_integer()) :: byte()
  defp flags_byte(flags_bin, idx) when idx >= 0 do
    if byte_size(flags_bin) > idx, do: :binary.at(flags_bin, idx), else: 0
  end

  @spec flags([endpoint()]) :: binary()
  defp flags(endpoints), do: :binary.copy(<<0>>, length(endpoints))

  @spec maybe_put([{binary(), binary()}], binary(), binary()) :: [{binary(), binary()}]
  defp maybe_put(fields, _key, <<>>), do: fields

  defp maybe_put(fields, key, value) when is_binary(value), do: [{key, value} | fields]
end

defmodule Magnet do
  @moduledoc """
  Parses magnet URIs into info hash, tracker URLs, and display name.

  Magnet links are a de-facto convention (documented on the BitTorrent wiki and
  used by every major client). They are not a numbered BEP, but `xt=urn:btih:`
  maps directly to the 20-byte info hash defined in BEP 3.
  """

  @type t :: %__MODULE__{
          hash: Torrent.hash(),
          hash_v2: Torrent.hash_v2() | nil,
          kind: Torrent.kind(),
          trackers: [String.t()],
          x_pe_peers: [Peer.t()],
          display_name: String.t() | nil
        }

  defstruct [:hash, :hash_v2, :trackers, :display_name, kind: :v1, x_pe_peers: []]

  @btih_prefix "urn:btih:"
  # BEP 52 § Extension to the magnet URI format — a v2 torrent's info_hash is
  # encoded as a multihash (multiformats.io) rather than a raw hex/base32 SHA-1.
  # sha2-256 is multicodec `0x12`; the digest is 32 bytes, so the multihash
  # prefix is <<0x12, 0x20>> = "1220" in lowercase hex. In base32 the same
  # prefix bytes serialize to "CIQ" — matches qBittorrent's convention.
  @btmh_prefix "urn:btmh:"

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(uri) when is_binary(uri) do
    uri
    |> String.trim()
    |> do_parse()
  end

  @spec do_parse(String.t()) :: {:ok, t()} | {:error, term()}
  defp do_parse(uri) do
    with {:ok, params, query} <- parse_magnet_query(uri),
         {:ok, hash_v1, hash_v2, kind} <- classify_xt(extract_xt_values(query)) do
      {:ok,
       build_magnet(
         params,
         hash_v1,
         hash_v2,
         kind,
         extract_trackers(query),
         extract_x_pe(query)
       )}
    end
  end

  @spec parse_magnet_query(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  defp parse_magnet_query(uri) do
    case URI.parse(uri) do
      %URI{scheme: "magnet", query: query} when is_binary(query) ->
        case URI.decode_query(query) do
          params when is_map(params) -> {:ok, params, query}
          _ -> {:error, :invalid_magnet}
        end

      %URI{scheme: scheme} when scheme != "magnet" ->
        {:error, :invalid_scheme}

      %URI{query: nil} ->
        {:error, :missing_query}

      _ ->
        {:error, :invalid_magnet}
    end
  end

  @spec build_magnet(
          map(),
          Torrent.hash(),
          Torrent.hash_v2() | nil,
          Torrent.kind(),
          [String.t()],
          [
            Peer.t()
          ]
        ) :: t()
  defp build_magnet(params, hash_v1, hash_v2, kind, trackers, x_pe_peers) do
    %__MODULE__{
      hash: hash_v1,
      hash_v2: hash_v2,
      kind: kind,
      trackers: trackers,
      x_pe_peers: x_pe_peers,
      display_name: Map.get(params, "dn")
    }
  end

  @spec metadata_left() :: pos_integer()
  def metadata_left, do: 16_384

  @doc """
  Splices the raw bencoded info blob into a top-level torrent dict.

  Takes the exact bytes verified against the magnet's info_hash (BEP 9) — never a
  re-encoded map — so parsing the resulting file recovers the same info_hash.
  Keys are emitted in bencode-canonical order: "announce" < "announce-list" < "info".
  """
  @spec build_torrent!(t(), binary()) :: binary()
  def build_torrent!(%__MODULE__{trackers: trackers}, info_blob) when is_binary(info_blob) do
    announce = announce_prefix(trackers)
    IO.iodata_to_binary(["d", announce, "4:info", info_blob, "e"])
  end

  @spec announce_prefix([String.t()]) :: iodata()
  defp announce_prefix([]), do: []

  defp announce_prefix([tracker]),
    do: ["8:announce", Bento.encode!(tracker)]

  defp announce_prefix([first | _] = trackers) do
    [
      "8:announce",
      Bento.encode!(first),
      "13:announce-list",
      Bento.encode!(Enum.map(trackers, &[&1]))
    ]
  end

  # Extract every raw `xt=…` (or `xt.N=…`) value from the query string, in
  # order. Walking the raw split preserves duplicate keys — libtorrent-style
  # hybrid magnets encode both `xt=urn:btih:…` and `xt=urn:btmh:…` under the
  # same key, and `URI.decode_query/1` would collapse them to the last one.
  @spec extract_xt_values(String.t()) :: [String.t()]
  defp extract_xt_values(query) when is_binary(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.flat_map(&xt_value_from_pair/1)
  end

  @spec xt_value_from_pair(String.t()) :: [String.t()]
  defp xt_value_from_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] ->
        key = URI.decode(key)

        if key == "xt" or String.starts_with?(key, "xt.") do
          [URI.decode(value)]
        else
          []
        end

      _ ->
        []
    end
  end

  # Fold the collected xt values into {v1_hash, v2_hash, kind}. Anything we
  # don't recognise (e.g. `urn:sha1:…` legacy variant) is ignored so a magnet
  # that also carries a valid btih/btmh still parses.
  @spec classify_xt([String.t()]) ::
          {:ok, Torrent.hash(), Torrent.hash_v2() | nil, Torrent.kind()} | {:error, term()}
  defp classify_xt([]), do: {:error, :missing_xt}

  defp classify_xt(values) do
    values
    |> Enum.reduce_while({nil, nil}, fn value, {v1, v2} ->
      case classify_one(value) do
        {:v1, hash} -> {:cont, {v1 || hash, v2}}
        {:v2, hash} -> {:cont, {v1, v2 || hash}}
        {:error, _} = err -> {:halt, err}
        :ignore -> {:cont, {v1, v2}}
      end
    end)
    |> finalize_xt_classification()
  end

  @spec finalize_xt_classification(term()) ::
          {:ok, Torrent.hash(), Torrent.hash_v2() | nil, Torrent.kind()} | {:error, term()}
  defp finalize_xt_classification({nil, nil}), do: {:error, :missing_xt}

  defp finalize_xt_classification({v1, nil}) when is_binary(v1),
    do: {:ok, v1, nil, :v1}

  defp finalize_xt_classification({v1, v2}) when is_binary(v1) and is_binary(v2),
    do: {:ok, v1, v2, :hybrid}

  defp finalize_xt_classification({nil, _v2}),
    do: {:error, :v2_only_unsupported}

  defp finalize_xt_classification({:error, _} = error), do: error

  @spec classify_one(String.t()) ::
          {:v1, Torrent.hash()} | {:v2, Torrent.hash_v2()} | {:error, term()} | :ignore
  defp classify_one(@btih_prefix <> encoded) do
    case decode_btih(encoded) do
      {:ok, hash} -> {:v1, hash}
      err -> err
    end
  end

  defp classify_one(@btmh_prefix <> encoded) do
    case decode_btmh(encoded) do
      {:ok, hash} -> {:v2, hash}
      err -> err
    end
  end

  defp classify_one(_), do: :ignore

  @spec decode_btih(String.t()) :: {:ok, Torrent.hash()} | {:error, term()}
  defp decode_btih(encoded) do
    encoded = String.downcase(encoded)

    cond do
      String.match?(encoded, ~r/^[0-9a-f]{40}$/) ->
        case Base.decode16(encoded, case: :mixed) do
          {:ok, <<hash::binary-size(20)>>} -> {:ok, hash}
          _ -> {:error, :invalid_btih}
        end

      String.match?(encoded, ~r/^[a-z2-7]{32}$/) ->
        case Base.decode32(String.upcase(encoded), padding: false) do
          {:ok, <<hash::binary-size(20)>>} -> {:ok, hash}
          _ -> {:error, :invalid_btih}
        end

      true ->
        {:error, :invalid_btih}
    end
  end

  # BEP 52 § "The urn is followed by a multihash-encoded infohash".
  # sha2-256 multihash = <<0x12, 0x20>> || <<32-byte digest>>. Both hex (68
  # chars) and base32-unpadded (55 chars) are seen in the wild; qBittorrent
  # emits hex, mainline emits base32. Anything else — including the raw
  # 32-byte SHA-256 without the multihash prefix — is rejected as invalid.
  @spec decode_btmh(String.t()) :: {:ok, Torrent.hash_v2()} | {:error, term()}
  defp decode_btmh(encoded) do
    encoded = String.downcase(encoded)

    cond do
      String.match?(encoded, ~r/^[0-9a-f]{68}$/) ->
        case Base.decode16(encoded, case: :mixed) do
          {:ok, <<0x12, 0x20, hash::binary-size(32)>>} -> {:ok, hash}
          _ -> {:error, :invalid_btmh}
        end

      String.match?(encoded, ~r/^[a-z2-7]{55}$/) ->
        case Base.decode32(String.upcase(encoded), padding: false) do
          {:ok, <<0x12, 0x20, hash::binary-size(32)>>} -> {:ok, hash}
          _ -> {:error, :invalid_btmh}
        end

      true ->
        {:error, :invalid_btmh}
    end
  end

  @doc false
  @spec private?(map()) :: boolean()
  def private?(info) when is_map(info), do: Map.get(info, "private") == 1

  @spec extract_x_pe(String.t()) :: [Peer.t()]
  defp extract_x_pe(query) when is_binary(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.flat_map(&x_pe_from_pair/1)
    |> Enum.uniq_by(&{&1.ip, &1.port})
  end

  @spec x_pe_from_pair(String.t()) :: [Peer.t()]
  defp x_pe_from_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> x_pe_value_if_key(URI.decode(key), URI.decode(value))
      _ -> []
    end
  end

  @spec x_pe_value_if_key(String.t(), String.t()) :: [Peer.t()]
  defp x_pe_value_if_key(key, value) do
    if key == "x.pe" or String.starts_with?(key, "x.pe.") do
      case parse_x_pe_endpoint(value) do
        {:ok, peer} -> [peer]
        :error -> []
      end
    else
      []
    end
  end

  @spec parse_x_pe_endpoint(String.t()) :: {:ok, Peer.t()} | :error
  defp parse_x_pe_endpoint(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [host, port_str] ->
        with {port, ""} <- Integer.parse(port_str),
             port when port > 0 and port <= 65_535 <- port,
             {:ok, ip} <- parse_ipv4(host) do
          {:ok, %Peer{ip: ip, port: port}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @spec parse_ipv4(String.t()) :: {:ok, :inet.ip4_address()} | :error
  defp parse_ipv4(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {a, b, c, d}} -> {:ok, {a, b, c, d}}
      _ -> :error
    end
  end

  @spec extract_trackers(String.t()) :: [String.t()]
  defp extract_trackers(query) when is_binary(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.flat_map(&tracker_from_pair/1)
    |> Enum.map(&normalize_tracker/1)
    |> Enum.uniq()
  end

  @spec tracker_from_pair(String.t()) :: [String.t()]
  defp tracker_from_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] ->
        key = URI.decode(key)

        if key == "tr" or String.starts_with?(key, "tr.") do
          [URI.decode(value)]
        else
          []
        end

      _ ->
        []
    end
  end

  @doc false
  @spec merge_trackers(t(), t()) :: t()
  def merge_trackers(%__MODULE__{} = base, %__MODULE__{} = incoming) do
    trackers = (base.trackers ++ incoming.trackers) |> Enum.uniq()
    display_name = base.display_name || incoming.display_name
    # Prefer the base kind/hash_v2 unless base is purely v1 and incoming has
    # v2 info — a hybrid magnet with more xt values collected later should
    # still upgrade the kind. Never downgrade :hybrid → :v1.
    {kind, hash_v2} =
      case {base.kind, incoming.kind} do
        {:v1, :hybrid} -> {:hybrid, incoming.hash_v2}
        {_, _} -> {base.kind, base.hash_v2 || incoming.hash_v2}
      end

    %{
      base
      | trackers: trackers,
        display_name: display_name,
        kind: kind,
        hash_v2: hash_v2,
        x_pe_peers: Enum.uniq_by(base.x_pe_peers ++ incoming.x_pe_peers, &{&1.ip, &1.port})
    }
  end

  @spec normalize_tracker(String.t()) :: String.t()
  defp normalize_tracker(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} = uri when scheme in ["http", "https", "udp", "udp4", "udp6"] ->
        path = uri.path

        if path in [nil, "", "/"] do
          URI.to_string(%{uri | path: "/announce"})
        else
          url
        end

      _ ->
        url
    end
  end
end

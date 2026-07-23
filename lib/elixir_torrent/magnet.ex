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
    uri = String.trim(uri)

    with %URI{scheme: "magnet", query: query} when is_binary(query) <- URI.parse(uri),
         params when is_map(params) <- URI.decode_query(query),
         xt_values <- extract_xt_values(query),
         {:ok, hash_v1, hash_v2, kind} <- classify_xt(xt_values),
         trackers <- extract_trackers(query),
         x_pe_peers <- extract_x_pe(query) do
      {:ok,
       %__MODULE__{
         hash: hash_v1,
         hash_v2: hash_v2,
         kind: kind,
         trackers: trackers,
         x_pe_peers: x_pe_peers,
         display_name: Map.get(params, "dn")
       }}
    else
      %URI{scheme: scheme} when scheme != "magnet" ->
        {:error, :invalid_scheme}

      %URI{query: nil} ->
        {:error, :missing_query}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_magnet}
    end
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
    |> Enum.flat_map(fn pair ->
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
    end)
  end

  # Fold the collected xt values into {v1_hash, v2_hash, kind}. Anything we
  # don't recognise (e.g. `urn:sha1:…` legacy variant) is ignored so a magnet
  # that also carries a valid btih/btmh still parses.
  @spec classify_xt([String.t()]) ::
          {:ok, Torrent.hash(), Torrent.hash_v2() | nil, Torrent.kind()} | {:error, term()}
  defp classify_xt([]), do: {:error, :missing_xt}

  defp classify_xt(values) do
    Enum.reduce_while(values, {nil, nil}, fn value, {v1, v2} ->
      case classify_one(value) do
        {:v1, hash} -> {:cont, {v1 || hash, v2}}
        {:v2, hash} -> {:cont, {v1, v2 || hash}}
        {:error, _} = err -> {:halt, err}
        :ignore -> {:cont, {v1, v2}}
      end
    end)
    |> case do
      {nil, nil} ->
        {:error, :missing_xt}

      {v1, nil} when is_binary(v1) ->
        {:ok, v1, nil, :v1}

      {v1, v2} when is_binary(v1) and is_binary(v2) ->
        {:ok, v1, v2, :hybrid}

      {nil, _v2} ->
        # Pure BEP 52 magnets carry only a btmh xt. Serving them without any
        # v1 identifier means every DHT/tracker/wire lookup would use the
        # truncated SHA-256 — which needs the full v2 stack (merkle
        # verification, hash-request extension messages, piece layers). None
        # of that has landed yet, so reject cleanly instead of accepting a
        # link we cannot actually fetch.
        {:error, :v2_only_unsupported}

      {:error, _} = error ->
        error
    end
  end

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
    |> Enum.flat_map(fn
      pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] ->
            key = URI.decode(key)

            if key == "x.pe" or String.starts_with?(key, "x.pe.") do
              case parse_x_pe_endpoint(URI.decode(value)) do
                {:ok, peer} -> [peer]
                :error -> []
              end
            else
              []
            end

          _ ->
            []
        end
    end)
    |> Enum.uniq_by(&{&1.ip, &1.port})
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
    |> Enum.flat_map(fn
      pair ->
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
    end)
    |> Enum.map(&normalize_tracker/1)
    |> Enum.uniq()
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

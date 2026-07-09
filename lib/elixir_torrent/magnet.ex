defmodule Magnet do
  @moduledoc """
  Parses magnet URIs into info hash, tracker URLs, and display name.

  Magnet links are a de-facto convention (documented on the BitTorrent wiki and
  used by every major client). They are not a numbered BEP, but `xt=urn:btih:`
  maps directly to the 20-byte info hash defined in BEP 3.
  """

  @type t :: %__MODULE__{
          hash: Torrent.hash(),
          trackers: [String.t()],
          x_pe_peers: [Peer.t()],
          display_name: String.t() | nil
        }

  defstruct [:hash, :trackers, :display_name, x_pe_peers: []]

  @btih_prefix "urn:btih:"

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(uri) when is_binary(uri) do
    uri = String.trim(uri)

    with %URI{scheme: "magnet", query: query} when is_binary(query) <- URI.parse(uri),
         params when is_map(params) <- URI.decode_query(query),
         {:ok, hash} <- parse_xt(params),
         trackers <- extract_trackers(query),
         x_pe_peers <- extract_x_pe(query) do
      {:ok,
       %__MODULE__{
         hash: hash,
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

  @spec build_torrent!(t(), map()) :: iodata()
  def build_torrent!(%__MODULE__{trackers: trackers}, info) when is_map(info) do
    metadata =
      trackers
      |> announce_fields()
      |> Map.put("info", info)
      |> Bento.encode!()

    metadata
  end

  @spec announce_fields([String.t()]) :: map()
  defp announce_fields([]), do: %{}

  defp announce_fields([tracker]), do: %{"announce" => tracker}

  defp announce_fields([first | rest]) do
    %{
      "announce" => first,
      "announce-list" => Enum.map([first | rest], &[&1])
    }
  end

  @spec parse_xt(map()) :: {:ok, Torrent.hash()} | {:error, term()}
  defp parse_xt(params) do
    xt =
      params
      |> Enum.find_value(fn
        {"xt", value} -> value
        {"xt." <> _, value} -> value
        _ -> nil
      end)

    with xt when is_binary(xt) <- xt,
         {:ok, hash} <- decode_btih(xt) do
      {:ok, hash}
    else
      nil -> {:error, :missing_xt}
      {:error, _} = error -> error
    end
  end

  @spec decode_btih(String.t()) :: {:ok, Torrent.hash()} | {:error, term()}
  defp decode_btih(@btih_prefix <> encoded) do
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

    %{
      base
      | trackers: trackers,
        display_name: display_name,
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

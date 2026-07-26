defmodule Peer.ConnectionManager.Queue do
  @moduledoc false

  alias Peer.UtPex.{BEP40, Filter}

  # `:discovery` — tracker, DHT, LSD, magnet, productive re-offer, etc. PEX drops
  # must not revoke this tag. `{:pex, remote_id}` — one tag per remote ut_pex supplier.
  @type source :: :discovery | {:pex, binary()}
  @type key :: {:inet.ip_address(), :inet.port_number()}
  @type t :: %{key() => entry()}
  @type entry :: %__MODULE__{
          peer: Peer.t(),
          sources: MapSet.t(source())
        }

  defstruct [:peer, sources: MapSet.new()]

  @max_global_pex_entries 256
  @max_pex_per_source 64

  @doc false
  @spec offer(t(), [Peer.t()], source(), keyword()) :: t()
  def offer(queue, peers, source, opts \\ []) when is_list(peers) do
    hash = Keyword.get(opts, :hash)
    clients = Keyword.get(opts, :clients, %{inet: nil, inet6: nil})

    peers
    |> filter_for_offer(source, hash)
    |> sort_peers_for_offer(clients)
    |> Enum.reduce(queue, fn %Peer{} = peer, acc ->
      if match?({:pex, _}, source) and duplicate_ip_blocked?(acc, peer) do
        acc
      else
        key = {peer.ip, peer.port}
        entry = Map.get(acc, key)
        Map.put(acc, key, merge_offer(entry, peer, source))
      end
    end)
    |> trim_pex_retention(clients)
  end

  @doc false
  @spec revoke_pex(t(), binary(), [Peer.t() | key()]) :: t()
  def revoke_pex(queue, pex_source, endpoints)
      when is_binary(pex_source) and byte_size(pex_source) == 20 and is_list(endpoints) do
    tag = {:pex, pex_source}

    Enum.reduce(endpoints, queue, fn endpoint, acc ->
      key = endpoint_key(endpoint)

      case Map.get(acc, key) do
        nil ->
          acc

        %__MODULE__{sources: sources} = entry ->
          update_revoke_sources(acc, key, entry, sources, tag)
      end
    end)
  end

  defp update_revoke_sources(acc, key, entry, sources, tag) do
    sources = MapSet.delete(sources, tag)

    if MapSet.size(sources) == 0 do
      Map.delete(acc, key)
    else
      Map.put(acc, key, %{entry | sources: sources})
    end
  end

  @doc false
  @spec peers(t()) :: [Peer.t()]
  def peers(queue) when is_map(queue), do: Enum.map(queue, fn {_k, %__MODULE__{peer: p}} -> p end)

  @doc false
  @spec get_peer(t(), key()) :: Peer.t() | nil
  def get_peer(queue, key) do
    case Map.get(queue, key) do
      %__MODULE__{peer: peer} -> peer
      _ -> nil
    end
  end

  @doc false
  @spec max_global_pex_entries() :: pos_integer()
  def max_global_pex_entries, do: @max_global_pex_entries

  @doc false
  @spec max_pex_per_source() :: pos_integer()
  def max_pex_per_source, do: @max_pex_per_source

  @spec filter_for_offer([Peer.t()], source(), Torrent.hash() | nil) :: [Peer.t()]
  defp filter_for_offer(peers, {:pex, _}, hash) when is_binary(hash),
    do: Filter.filter_peers(peers, hash)

  defp filter_for_offer(peers, _source, _hash), do: peers

  @spec sort_peers_for_offer([Peer.t()], map()) :: [Peer.t()]
  defp sort_peers_for_offer(peers, clients) do
    Enum.sort_by(peers, fn %Peer{ip: ip, port: port} ->
      family = if tuple_size(ip) == 4, do: :inet, else: :inet6
      client = Map.get(clients, family)

      priority =
        case client && BEP40.priority(client, {ip, port}) do
          {:ok, value} -> value
          _ -> 0
        end

      {if(family == :inet, do: 0, else: 1), Bitwise.bxor(priority, 0xFFFFFFFF), {ip, port}}
    end)
  end

  @doc false
  @spec duplicate_ip_blocked?(t(), Peer.t()) :: boolean()
  def duplicate_ip_blocked?(queue, %Peer{ip: ip, port: port}) when is_map(queue) do
    Filter.duplicate_ip_blocked?(queue, %Peer{ip: ip, port: port})
  end

  @spec trim_pex_retention(t(), term()) :: t()
  defp trim_pex_retention(queue, clients) do
    queue
    |> enforce_per_source_caps(clients)
    |> enforce_global_pex_cap(clients)
  end

  @spec enforce_per_source_caps(t(), term()) :: t()
  defp enforce_per_source_caps(queue, clients) do
    pex_sources =
      queue
      |> Map.values()
      |> Enum.flat_map(fn %__MODULE__{sources: sources} ->
        sources |> MapSet.to_list() |> Enum.filter(&match?({:pex, _}, &1))
      end)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(pex_sources, queue, fn {:pex, src} = tag, acc ->
      keys_for_source =
        acc
        |> Enum.filter(fn {_k, %__MODULE__{sources: sources}} -> MapSet.member?(sources, tag) end)
        |> Enum.map(fn {k, _} -> k end)

      if length(keys_for_source) <= @max_pex_per_source do
        acc
      else
        evict_over_cap_pex(acc, keys_for_source, tag, clients, src)
      end
    end)
  end

  defp evict_over_cap_pex(queue, keys_for_source, tag, clients, src) do
    evict_keys =
      keys_for_source
      |> sort_keys_for_eviction(queue, clients, src)
      |> Enum.take(length(keys_for_source) - @max_pex_per_source)

    Enum.reduce(evict_keys, queue, fn key, acc ->
      remove_source_tag(acc, key, tag)
    end)
  end

  @spec enforce_global_pex_cap(t(), term()) :: t()
  defp enforce_global_pex_cap(queue, clients) do
    pex_only_keys = pex_only_keys(queue)

    if length(pex_only_keys) <= @max_global_pex_entries do
      queue
    else
      evict_keys =
        pex_only_keys
        |> sort_keys_for_eviction(queue, clients, :global)
        |> Enum.take(length(pex_only_keys) - @max_global_pex_entries)

      Enum.reduce(evict_keys, queue, &evict_pex_only/2)
    end
  end

  @spec pex_only_keys(t()) :: [key()]
  defp pex_only_keys(queue) do
    Enum.flat_map(queue, fn
      {k, %__MODULE__{sources: sources}} ->
        if MapSet.member?(sources, :discovery), do: [], else: [k]

      _ ->
        []
    end)
  end

  @spec evict_pex_only(key(), t()) :: t()
  defp evict_pex_only(key, queue) do
    case Map.get(queue, key) do
      %__MODULE__{sources: sources} ->
        if MapSet.member?(sources, :discovery), do: queue, else: Map.delete(queue, key)

      _ ->
        queue
    end
  end

  @spec remove_source_tag(t(), key(), source()) :: t()
  defp remove_source_tag(queue, key, tag) do
    case Map.get(queue, key) do
      %__MODULE__{sources: sources} = entry ->
        sources = MapSet.delete(sources, tag)

        if MapSet.size(sources) == 0,
          do: Map.delete(queue, key),
          else: Map.put(queue, key, %{entry | sources: sources})

      _ ->
        queue
    end
  end

  @spec sort_keys_for_eviction([key()], t(), term(), term()) :: [key()]
  defp sort_keys_for_eviction(keys, queue, clients, _scope) when is_map(clients) do
    Enum.sort_by(keys, fn key ->
      %__MODULE__{peer: %Peer{ip: ip, port: port}} = Map.fetch!(queue, key)
      client = Map.get(clients, if(tuple_size(ip) == 4, do: :inet, else: :inet6))

      priority =
        case client && BEP40.priority(client, {ip, port}) do
          {:ok, value} -> value
          _ -> -1
        end

      {priority, key}
    end)
  end

  defp sort_keys_for_eviction(keys, _queue, _clients, _scope), do: Enum.sort(keys)

  @spec merge_offer(entry() | nil, Peer.t(), source()) :: entry()
  defp merge_offer(nil, %Peer{} = peer, source) do
    %__MODULE__{peer: peer, sources: MapSet.new([source])}
  end

  defp merge_offer(%__MODULE__{peer: existing, sources: sources}, %Peer{} = incoming, source) do
    seed = existing.seed == true or incoming.seed == true

    peer = %Peer{
      incoming
      | seed: if(seed, do: true, else: incoming.seed)
    }

    %__MODULE__{peer: peer, sources: MapSet.put(sources, source)}
  end

  @spec endpoint_key(Peer.t() | key()) :: key()
  defp endpoint_key({ip, port}) when is_tuple(ip), do: {ip, port}
  defp endpoint_key(%Peer{ip: ip, port: port}), do: {ip, port}
end

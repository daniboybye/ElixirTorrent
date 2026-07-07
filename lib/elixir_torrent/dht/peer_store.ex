defmodule DHT.PeerStore do
  @moduledoc """
  BEP 5 § get_peers / announce_peer — server-side peer contact storage per info hash.

  Stores compact peers learned from announce_peer queries with a bounded TTL.
  """

  @default_ttl_ms 30 * 60 * 1_000
  @max_peers_per_hash 50
  @max_hashes 256

  @type t :: %{Torrent.hash() => [%{peer: Peer.t(), expires_ms: non_neg_integer()}]}

  @doc "Record a peer announced for `info_hash`."
  @spec put(t(), Torrent.hash(), Peer.t(), keyword()) :: t()
  def put(store, info_hash, %Peer{} = peer, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())
    expires = now + Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    peers =
      store
      |> Map.get(info_hash, [])
      |> Enum.reject(fn %{peer: p} -> same_peer?(p, peer) end)
      |> then(&[%{peer: peer, expires_ms: expires} | &1])
      |> Enum.take(@max_peers_per_hash)

    store
    |> Map.put(info_hash, peers)
    |> trim_hashes()
  end

  @doc "Return non-expired peers for `info_hash`."
  @spec get(t(), Torrent.hash(), keyword()) :: [Peer.t()]
  def get(store, info_hash, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    store
    |> Map.get(info_hash, [])
    |> Enum.reject(fn %{expires_ms: exp} -> exp <= now end)
    |> Enum.map(& &1.peer)
  end

  @doc "Drop expired entries from the store."
  @spec prune(t(), keyword()) :: t()
  def prune(store, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    store
    |> Map.new(fn {hash, peers} ->
      {hash, Enum.reject(peers, fn %{expires_ms: exp} -> exp <= now end)}
    end)
    |> Enum.reject(fn {_hash, peers} -> peers == [] end)
    |> Map.new()
  end

  @spec same_peer?(Peer.t(), Peer.t()) :: boolean()
  defp same_peer?(a, b), do: a.ip == b.ip and a.port == b.port

  @spec trim_hashes(t()) :: t()
  defp trim_hashes(store) when map_size(store) <= @max_hashes, do: store

  defp trim_hashes(store) do
    store
    |> Enum.take(@max_hashes)
    |> Map.new()
  end

  @spec now_ms() :: non_neg_integer()
  defp now_ms, do: System.monotonic_time(:millisecond)
end

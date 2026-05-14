defmodule PeerDiscovery.SeedPeers do
  @moduledoc """
  Hand-off table for peer endpoints known before a torrent's `Announce` process exists.

  BEP 9 § Magnet URI format lets a magnet embed `x.pe=<host>:<port>` fallback peers.
  `Magnet.Fetcher` uses them to bootstrap metadata retrieval, but by the time the
  full torrent supervisor comes up (metadata → disk → `Torrent.start_link`) the
  fetcher process is gone and those endpoints would be lost. This table bridges
  the gap: `put/2` at magnet-metadata-complete time, `take/1` from `Announce.init`.

  Backed by a public `:set` ETS table owned by a tiny GenServer so the table
  survives the writer/reader lifecycles independently. Entries are single-consumer:
  `take/1` deletes the row atomically, so a re-added torrent for the same hash
  starts with a clean seed slot.
  """

  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Add seed peers for `hash`. Multiple calls accumulate; duplicates by `{ip, port}` collapse.
  """
  @spec put(Torrent.hash(), [Peer.t()]) :: :ok
  def put(_hash, []), do: :ok

  def put(hash, peers) when is_binary(hash) and is_list(peers) do
    ensure_table()

    existing =
      case :ets.lookup(@table, hash) do
        [{^hash, list}] -> list
        _ -> []
      end

    merged = Enum.uniq_by(existing ++ peers, &{&1.ip, &1.port})
    :ets.insert(@table, {hash, merged})
    :ok
  end

  @doc """
  Read and remove seed peers for `hash`. Returns `[]` when nothing was stashed.
  """
  @spec take(Torrent.hash()) :: [Peer.t()]
  def take(hash) when is_binary(hash) do
    ensure_table()

    case :ets.take(@table, hash) do
      [{^hash, peers}] -> peers
      _ -> []
    end
  end

  # The Announce worker can start before this GenServer in test setups that skip
  # the PeerDiscovery supervisor tree; make the table lazily.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end

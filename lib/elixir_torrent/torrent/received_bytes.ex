defmodule Torrent.ReceivedBytes do
  @moduledoc """
  Per-torrent count of piece payload bytes received from peers.

  The download readout used to be derived from `Torrent.Model.downloaded`, which
  advances only when a whole piece completes and verifies: at 64 KB/s with 1 MiB
  pieces it moves once every ~16 s, so any short window reads 0 or a burst, and a
  long one lags (PLAN #53b). Every `Peer.Controller` already knows the exact size
  of each block it accepts; this table adds those sizes up per info-hash so the
  Model can difference a byte-granular counter instead.

  `:ets.update_counter/4` on a `write_concurrency` table is an atomic in-place
  increment with no message passing, so the hot receive path pays one ETS write
  per 16 KiB block (~130/s at 2 MB/s). The table is owned by this process, not by
  a torrent, so it survives a Model or peer restart; a missing table (a test that
  did not start the application) makes `add/2` a no-op.
  """

  use GenServer

  @table :elixir_torrent_received_bytes

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    {:ok, nil}
  end

  @doc "Adds `bytes` received for `hash`."
  @spec add(Torrent.hash(), non_neg_integer()) :: :ok
  def add(hash, bytes) when is_binary(hash) and is_integer(bytes) and bytes >= 0 do
    _ = :ets.update_counter(@table, hash, bytes, {hash, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Total bytes received for `hash` since the counter was created."
  @spec total(Torrent.hash()) :: non_neg_integer()
  def total(hash) when is_binary(hash) do
    case :ets.lookup(@table, hash) do
      [{^hash, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Forgets the counter for `hash` (the torrent was removed)."
  @spec delete(Torrent.hash()) :: :ok
  def delete(hash) when is_binary(hash) do
    _ = :ets.delete(@table, hash)
    :ok
  rescue
    ArgumentError -> :ok
  end
end

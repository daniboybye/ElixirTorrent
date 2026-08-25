defmodule Magnet.Fetcher.DhtBackgroundStore do
  @moduledoc """
  Permanent owner of the background DHT lookup table.

  ETS tables die with the process that created them. The deep `get_peers` retry
  runs in a detached task that outlives the fetch round which started it, so
  letting whichever caller happened to touch the table first own it meant the
  task's result insert crashed with `ArgumentError` as soon as that caller was
  gone — losing the peers it had just spent ~13s finding.
  """

  use GenServer

  @table :magnet_fetcher_dht_background

  @spec table() :: atom()
  def table, do: @table

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, nil}
  def init(_opts) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, read_concurrency: true])
    end

    {:ok, nil}
  end
end

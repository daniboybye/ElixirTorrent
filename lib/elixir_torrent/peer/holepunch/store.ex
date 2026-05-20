defmodule Peer.Holepunch.Store do
  @moduledoc """
  Permanent owner of the hole-punch attempt table.

  ETS tables die with the process that created them; the attempt/backoff state
  must outlive the dialing tasks and connection managers that consult it.
  """

  use GenServer

  @table :elixir_torrent_holepunch_pending

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, nil}
  def init(_opts) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end

    {:ok, nil}
  end
end

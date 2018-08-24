defmodule Torrents do
  use DynamicSupervisor, type: :supervisor, start: {__MODULE__, :start_link, []}

  @spec start_link() :: Supervisor.on_start()
  def start_link() do
    DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec download(Path.t(), Keyword.t()) :: DynamicSupervisor.on_start_child()
  def download(path, options \\ []) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Torrent, {path, options}}
    )
  end

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10)
  end
end

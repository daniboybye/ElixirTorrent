defmodule Torrents do
  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {
        DynamicSupervisor,
        :start_link,
        [[name: __MODULE__, strategy: :one_for_one, max_restarts: 0]]
      }
    }
  end

  @spec download(Path.t()) :: DynamicSupervisor.on_start_child()
  def download(path) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Torrent, path}
    )
  end
end

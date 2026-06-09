defmodule Torrents do
  @moduledoc """
  Internal runtime facade used by `ElixirTorrent`.

  Use `ElixirTorrent` as the preferred public API.
  """

  @default_stats_fields [:name, :speed, :downloaded, :bytes_size]

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
  @doc """
  Starts a new torrent download from a local `.torrent` path.

  Returns `{:ok, pid}` on success.
  """
  def download(path) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Torrent, path}
    )
  end

  @doc """
  Returns a default set of runtime stats for a torrent process.

  The default fields are:
  `[:name, :speed, :downloaded, :bytes_size]`.
  """
  @spec stats(pid()) :: {:ok, map()} | {:error, :torrent_not_found}
  def stats(pid), do: stats(pid, @default_stats_fields)

  @doc """
  Returns selected runtime fields for a torrent process as a map keyed by field.

  Example:

      Torrents.stats(pid, [:name, :speed, :downloaded, :bytes_size])
  """
  @spec stats(pid(), [atom()]) :: {:ok, map()} | {:error, :torrent_not_found}
  def stats(pid, fields) when is_list(fields) do
    case Torrent.get_hash(pid) do
      nil ->
        {:error, :torrent_not_found}

      hash ->
        values = Torrent.get(hash, fields)
        {:ok, Enum.zip(fields, values) |> Map.new()}
    end
  end

  @doc """
  Stops a running torrent and removes it from the active list.

  When `:delete_data` is `true`, downloaded files are deleted from disk after
  the torrent process has been stopped.
  """
  @spec remove(Torrent.hash(), keyword()) :: :ok | {:error, term()}
  def remove(hash, opts \\ []) do
    delete_data? = Keyword.get(opts, :delete_data, false)

    with {:ok, pid} <- find_pid(hash),
         paths <- if(delete_data?, do: Torrent.Removal.data_paths(hash), else: []),
         :ok <- stop_pid(pid),
         :ok <- maybe_delete_data(paths, delete_data?) do
      :ok
    end
  end

  @spec find_pid(Torrent.hash()) :: {:ok, pid()} | {:error, :not_found}
  def find_pid(hash) do
    case Enum.find_value(DynamicSupervisor.which_children(__MODULE__), fn
           {_id, pid, _type, _modules} when is_pid(pid) ->
             if Torrent.get_hash(pid) == hash, do: pid

           _ ->
             nil
         end) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  @spec stop_pid(pid()) :: :ok | {:error, term()}
  defp stop_pid(pid) do
    case Supervisor.stop(pid, :normal, 5_000) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec maybe_delete_data([Path.t()], boolean()) :: :ok
  defp maybe_delete_data(_paths, false), do: :ok
  defp maybe_delete_data(paths, true), do: Torrent.Removal.delete_paths!(paths)
end

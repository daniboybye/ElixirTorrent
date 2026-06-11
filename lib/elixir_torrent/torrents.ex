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
  @spec remove(binary(), keyword()) :: :ok | {:error, term()}
  def remove(hash, opts \\ []) do
    delete_data? = Keyword.get(opts, :delete_data, false)

    with {:ok, pid} <- find_pid(hash),
         paths <- if(delete_data?, do: Torrent.Removal.data_paths(hash), else: []),
         :ok <- stop_pid(pid),
         :ok <- Torrent.Session.delete(hash),
         :ok <- maybe_delete_data(paths, delete_data?) do
      :ok
    end
  end

  @doc """
  Stops a torrent, sends tracker `stopped`, persists session state, then stops the process.
  """
  @spec stop_and_serialize(binary()) :: :ok | {:error, term()}
  def stop_and_serialize(hash) do
    with {:ok, pid} <- find_pid(hash),
         :ok <- stop_downloads(hash),
         :ok <- disconnect_peers(hash),
         :ok <- announce_stopped(hash),
         :ok <- persist_session(hash),
         :ok <- stop_pid(pid) do
      :ok
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops every active torrent and persists session state for each one.
  """
  @spec stop_all_and_serialize() :: :ok
  def stop_all_and_serialize do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        case Torrent.get_hash(pid) do
          nil -> :ok
          hash -> _ = stop_and_serialize(hash)
        end

      _ ->
        :ok
    end)

    :ok
  end

  @doc """
  Returns info hashes for all active torrent processes.
  """
  @spec list() :: [binary()]
  def list do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        case Torrent.get_hash(pid) do
          nil -> []
          hash -> [hash]
        end

      _ ->
        []
    end)
  end

  @spec find_pid(binary()) :: {:ok, pid()} | {:error, :not_found}
  defp find_pid(hash) do
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

  @spec announce_stopped(binary()) :: :ok
  defp announce_stopped(hash) do
    Torrent.Model.set_event(hash, Torrent.stopped())
    PeerDiscovery.stopped_announce(hash)
  end

  @spec stop_downloads(binary()) :: :ok
  defp stop_downloads(hash) do
    Torrent.Downloads.stop(hash)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec disconnect_peers(binary()) :: :ok
  defp disconnect_peers(hash) do
    Torrent.Swarm.disconnect_all(hash)
  end

  @spec persist_session(binary()) :: :ok
  defp persist_session(hash) do
    Torrent.Session.save(hash, Torrent.Model.get(hash))
    :ok
  end
end

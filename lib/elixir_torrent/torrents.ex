defmodule Torrents do
  @moduledoc """
  Runtime supervisor and operations layer behind `ElixirTorrent`.

  Most callers should use `ElixirTorrent` directly. This module is published in
  HexDocs for API completeness — it owns the dynamic supervisor that starts torrent
  processes and implements `remove/2`, `stop_and_serialize/1`, and related lifecycle
  helpers.
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

  @doc """
  Returns the torrent supervisor pid for `hash`, if it is running.
  """
  @spec supervisor_pid(Torrent.hash()) :: {:ok, pid()} | {:error, :not_found}
  def supervisor_pid(hash), do: find_pid(hash)

  @doc """
  Starts a new torrent download from a local `.torrent` path.

  Options:

    * `:download_dir` — base directory for downloaded files (defaults to `File.cwd!/0`)

  Multi-file torrents with loose top-level files are written under a folder named
  after the torrent; torrents that already share a root folder keep their original paths.

  Returns `{:ok, pid}` on success.
  """
  @spec download(Path.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def download(path, opts \\ []) when is_list(opts) do
    %Torrent{hash: hash} = Torrent.parse_file!(path)

    case find_pid(hash) do
      {:ok, pid} ->
        :ok = PeerDiscovery.ensure_announce(hash)
        {:ok, pid}

      {:error, :not_found} ->
        case DynamicSupervisor.start_child(__MODULE__, {Torrent, {path, opts}}) do
          {:error, {:already_started, pid}} when is_pid(pid) ->
            :ok = PeerDiscovery.ensure_announce(hash)
            {:ok, pid}

          other ->
            other
        end
    end
  end

  @doc """
  Starts a download from a magnet URI.

  Fetches metadata over BEP 9 (`ut_metadata`) from peers discovered via magnet
  `tr=` tracker URLs (BEP 3/7/15/23), writes a `.torrent` file, then starts a
  normal torrent session.

  Trackerless magnets (no `tr=` and no DHT) return `{:error, :missing_trackers}`.
  """
  @spec download_magnet(String.t(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def download_magnet(magnet_uri, opts \\ []) when is_binary(magnet_uri) and is_list(opts) do
    with {:ok, %Magnet{} = magnet} <- Magnet.parse(magnet_uri),
         {:ok, ref} <- Magnet.Fetcher.run(magnet),
         {:ok, path} <- Magnet.Fetcher.await(ref),
         result <- download(path, Keyword.put(opts, :resume, :skip)) do
      result
    end
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
         download_root <-
           if(delete_data?, do: Torrent.Removal.download_root(hash), else: File.cwd!()),
         :ok <- stop_pid(pid),
         :ok <- Torrent.Session.delete(hash),
         :ok <- maybe_delete_data(paths, download_root, delete_data?) do
      :ok
    end
  end

  @doc """
  Gracefully stops a torrent and persists session state.

  Order of operations:

    1. Stop active piece downloads
    2. Disconnect all peers (BEP 3 messages, then TCP close)
    3. Tracker announce with `event=stopped`
    4. Write session to `.elixir_torrent/state/{hash}.term`
    5. Stop the torrent OTP process

  Returns `:ok` when the torrent is not found (already stopped).
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

  @spec maybe_delete_data([Path.t()], Path.t(), boolean()) :: :ok
  defp maybe_delete_data(_paths, _root, false), do: :ok
  defp maybe_delete_data(paths, root, true), do: Torrent.Removal.delete_paths!(paths, root)

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

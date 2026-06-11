defmodule ElixirTorrent do
  @moduledoc """
  Public API for controlling torrent downloads.

  This is the entrypoint you should use from other applications.
  Start a download with `download/1` and poll stats with `stats/2`.

  ## Public functions

    * `main/1` - starts the CLI loop used by the escript
    * `version/0` - returns this client's peer ID/version string
    * `download/1` - starts downloading a `.torrent` from disk
    * `stats/2` - fetches selected runtime stats for a torrent
    * `get/2` - low-level raw getter kept for compatibility
    * `list_files/1` - lists files with per-file download progress
    * `remove/2` - stops a torrent and optionally deletes its data
  """

  @typedoc "20-byte torrent info hash."
  @type info_hash :: binary()

  @typedoc """
  Per-file progress entry returned by `list_files/1`.

  Keys: `:index`, `:path`, `:name`, `:length`, `:downloaded`, `:progress`, `:complete?`.
  """
  @type file_entry :: %{
          index: non_neg_integer(),
          path: String.t(),
          name: String.t(),
          length: non_neg_integer(),
          downloaded: non_neg_integer(),
          progress: float(),
          complete?: boolean()
        }

  @doc "Starts the CLI loop used by the escript entrypoint."
  def main(_), do: loop()

  @doc "Returns the peer ID/version string advertised by this client."
  def version, do: "ET0-1-0"

  defp loop do
    parse(IO.read(:line))
    loop()
  end

  defp parse(<<"download ", path::binary>>) do
    {:ok, pid} = Torrents.download(path)

    Task.start(fn -> info(Torrent.get_hash(pid)) end)
  end

  defp parse(_), do: nil

  defp info(hash) do
    Process.sleep(45_000)
    [name, speed, downloaded, size] = Torrent.get(hash, [:name, :speed, :downloaded, :bytes_size])

    if downloaded === size do
      :normal
    else
      [
        name,
        "download: #{speed.download} Kb/s",
        "upload: #{speed.upload} Kb/s",
        "#{Float.ceil(downloaded * 100 / size)}%",
        "---------------------------------------"
      ]
      |> Enum.intersperse("\r\n")
      |> IO.puts()

      info(hash)
    end
  end

  @doc """
  Starts downloading a `.torrent` file from the given local path.

  Returns the same value as `Torrents.download/1`:
  `{:ok, pid}` on success or `{:error, reason}`.

  Example:

      {:ok, pid} = ElixirTorrent.download("/tmp/file.torrent")
  """
  defdelegate download(path), to: Torrents

  @doc """
  Returns selected runtime stats for a running torrent process.

  By default it returns:
  `:name`, `:speed`, `:downloaded`, `:bytes_size`.

  You can request custom fields, for example:

      ElixirTorrent.stats(pid, [:name, :speed, :downloaded, :bytes_size])

  Result shape:

      {:ok,
       %{
         name: "ubuntu.iso",
         speed: %{download: 1200, upload: 80},
         downloaded: 1048576,
         bytes_size: 4294967296
       }}
  """
  @spec stats(pid(), [atom()]) :: {:ok, map()} | {:error, :torrent_not_found}
  def stats(pid, fields \\ [:name, :speed, :downloaded, :bytes_size]),
    do: Torrents.stats(pid, fields)

  @doc """
  Low-level getter that proxies to the internal torrent model getter through the torrent pid.

  Prefer `stats/2` when you need runtime statistics as a map.
  """
  @spec get(pid(), atom() | [atom()]) :: any()
  def get(pid, args \\ []) do
    Torrent.get_hash(pid)
    |> Torrent.get(args)
  end

  @doc """
  Lists files in a torrent with per-file download progress.

  See `t:file_entry/0` for the shape of each returned entry.
  """
  @spec list_files(info_hash()) :: [file_entry()]
  defdelegate list_files(hash), to: Torrent, as: :list_files

  @doc """
  Stops a torrent and removes it from the active session.

  Pass `delete_data: true` to also delete downloaded files from disk.
  """
  @spec remove(info_hash(), keyword()) :: :ok | {:error, term()}
  defdelegate remove(hash, opts \\ []), to: Torrents

  @doc """
  Returns info hashes for all active torrent processes.
  """
  @spec list() :: [info_hash()]
  defdelegate list(), to: Torrents

  @doc """
  Stops a torrent and persists its session state to disk.
  """
  @spec stop_and_serialize(info_hash()) :: :ok | {:error, term()}
  defdelegate stop_and_serialize(hash), to: Torrents

  @doc """
  Stops every active torrent and persists session state for each one.
  """
  @spec stop_all_and_serialize() :: :ok
  defdelegate stop_all_and_serialize(), to: Torrents
end

defmodule ElixirTorrent do
  @moduledoc """
  Public API for the ElixirTorrent BitTorrent engine.

  Start the OTP application before calling any function:

      Application.ensure_all_started(:elixir_torrent)

  Then add torrents with `download/1` (or `download/2` with options), poll progress
  with `stats/2`, and shut down cleanly with `stop_and_serialize/1` when you need
  session state preserved on disk.

  ## Session persistence

  Session snapshots are written to `.elixir_torrent/state/{hex_info_hash}.term`
  under `File.cwd!/0` (independent of `:download_dir`). Calling `download/1` for a
  torrent with an existing session loads the saved bitfield and verifies pieces on
  disk before resuming.

  Use `stop_and_serialize/1` (or `stop_all_and_serialize/0`) before your app exits.
  Use `remove/2` when you want to drop a torrent from the active session; pass
  `delete_data: true` to also delete downloaded files.

  ## Public functions

    * `download/2` — start a download from a local `.torrent` path; optional `:download_dir`
    * `stats/2` — runtime stats as a map (preferred over `get/2`)
    * `list/0` — info hashes for all active torrent processes
    * `list_files/1` — per-file download progress
    * `stop_and_serialize/1` — graceful stop and persist session
    * `stop_all_and_serialize/0` — graceful stop and persist for every torrent
    * `remove/2` — stop and remove from session; optional `delete_data: true`
    * `get/2` — low-level field access
    * `version/0` — peer ID prefix advertised to peers (BEP 20)
    * `main/1` — escript CLI entrypoint

  See the [README](readme.html) for a full quick-start guide.
  """

  @typedoc "20-byte torrent info hash."
  @type info_hash :: binary()

  @typedoc """
  Per-file progress entry returned by `list_files/1`.

  Keys: `:index`, `:path`, `:name`, `:length`, `:downloaded`, `:progress`, `:complete?`.
  """
  @type file_entry :: Torrent.Files.Entry.t()

  @doc "Starts the CLI loop used by the escript entrypoint."
  def main(_), do: loop()

  @doc """
  Returns the peer ID prefix advertised to other peers (BEP 20).

  The full 20-byte peer ID is this prefix, a hyphen, and random bytes.
  """
  def version, do: "ET0-3-0"

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

  If a session file already exists for this torrent's info hash, progress is restored
  after verifying pieces on disk.

  Options:

    * `:download_dir` — base directory for downloaded files (defaults to `File.cwd!/0`)

  Session snapshots remain under `{File.cwd!()}/.elixir_torrent/state/` regardless of
  `:download_dir`. Multi-file torrents with loose top-level files are written under a
  folder named after the torrent; torrents that already share a root folder keep their
  original paths.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.

  ## Example

      {:ok, pid} = ElixirTorrent.download("/tmp/file.torrent")
      {:ok, pid} = ElixirTorrent.download("/tmp/file.torrent", download_dir: "/Downloads")
  """
  @spec download(Path.t(), keyword()) :: DynamicSupervisor.on_start_child()
  defdelegate download(path, opts \\ []), to: Torrents

  @doc """
  Starts downloading from a magnet link.

  Parses the URI, discovers peers via magnet `tr=` trackers, fetches the `info`
  dictionary with BEP 9 (`ut_metadata`), materializes a `.torrent` file, then
  starts a normal session via `download/1`.

  Requires at least one tracker URL in the magnet unless **BEP 5 DHT** is enabled.
  Trackerless magnets use DHT peer discovery when enabled; otherwise
  `{:error, :missing_trackers}`.

  ## Example

      {:ok, pid} =
        ElixirTorrent.download_magnet(
          "magnet:?xt=urn:btih:abc...&tr=udp%3A%2F%2Ftracker.example.com%3A80%2Fannounce"
        )
  """
  @spec download_magnet(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def download_magnet(magnet_uri, opts \\ []) when is_binary(magnet_uri) and is_list(opts) do
    case Torrents.download_magnet(magnet_uri, opts) do
      {:ok, pid} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Returns selected runtime stats for a running torrent process.

  Default fields: `:name`, `:speed`, `:downloaded`, `:bytes_size`.

  ## Example

      ElixirTorrent.stats(pid, [:name, :speed, :downloaded, :bytes_size])
      #=> {:ok, %{name: "ubuntu.iso", speed: %{download: 1200, upload: 80}, ...}}

  Returns `{:error, :torrent_not_found}` if the pid is not a live torrent process.
  """
  @spec stats(pid(), [atom()]) :: {:ok, map()} | {:error, :torrent_not_found}
  def stats(pid, fields \\ [:name, :speed, :downloaded, :bytes_size]),
    do: Torrents.stats(pid, fields)

  @doc """
  Low-level getter that reads fields from the internal torrent model.

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

  Deletes the on-disk session file. Pass `delete_data: true` to also remove
  downloaded files from disk.

  ## Example

      ElixirTorrent.remove(hash)
      ElixirTorrent.remove(hash, delete_data: true)
  """
  @spec remove(info_hash(), keyword()) :: :ok | {:error, term()}
  defdelegate remove(hash, opts \\ []), to: Torrents

  @doc """
  Returns info hashes for all active torrent processes.
  """
  @spec list() :: [info_hash()]
  defdelegate list(), to: Torrents

  @doc """
  Gracefully stops a torrent and persists its session state to disk.

  Steps: stop downloads → disconnect peers → tracker `event=stopped` →
  write `.elixir_torrent/state/{hash}.term` → stop the torrent process.

  Returns `:ok` if the torrent is not running (already stopped).
  """
  @spec stop_and_serialize(info_hash()) :: :ok | {:error, term()}
  defdelegate stop_and_serialize(hash), to: Torrents

  @doc """
  Gracefully stops every active torrent and persists session state for each one.

  Same shutdown sequence as `stop_and_serialize/1`, applied to all running torrents.
  """
  @spec stop_all_and_serialize() :: :ok
  defdelegate stop_all_and_serialize(), to: Torrents
end

defmodule ElixirTorrent do
  @moduledoc """
  Public API for controlling torrent downloads.

  This module exposes a small surface area intended for embedding the engine
  in other Elixir applications.

  ## Public functions

    * `main/1` - starts the CLI loop used by the escript
    * `version/0` - returns this client's peer ID/version string
    * `download/1` - starts downloading a `.torrent` from disk
    * `stats/2` - fetches selected runtime stats for a torrent
    * `get/2` - low-level raw getter kept for compatibility
  """

  @doc """
  Starts the CLI loop used by the escript entrypoint.
  """
  def main(_), do: loop()

  @doc """
  Returns the peer ID/version string advertised by this client.
  """
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
  """
  defdelegate download(path), to: Torrents

  @doc """
  Returns selected runtime stats for a running torrent process.

  By default it returns:
  `:name`, `:speed`, `:downloaded`, `:bytes_size`.

  You can request custom fields, for example:

      ElixirTorrent.stats(pid, [:name, :speed, :downloaded, :bytes_size])
  """
  @spec stats(pid(), [atom()]) :: {:ok, map()} | {:error, :torrent_not_found}
  def stats(pid, fields \\ [:name, :speed, :downloaded, :bytes_size]),
    do: Torrents.stats(pid, fields)

  @doc """
  Low-level getter that proxies to `Torrent.get/2` through the torrent pid.

  Prefer `stats/2` when you need runtime statistics as a map.
  """
  @spec get(pid(), atom() | [atom()]) :: any()
  def get(pid, args \\ []) do
    Torrent.get_hash(pid)
    |> Torrent.get(args)
  end
end

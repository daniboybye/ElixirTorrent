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
end

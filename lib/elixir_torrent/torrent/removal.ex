defmodule Torrent.Removal do
  @moduledoc false

  alias Torrent.{Model, PathLayout}

  @spec data_paths(Torrent.hash()) :: [Path.t()]
  def data_paths(hash) do
    hash
    |> Model.get()
    |> disk_paths()
  end

  @spec disk_paths(Torrent.t()) :: [Path.t()]
  def disk_paths(%Torrent{metadata: %{"info" => info}}) do
    PathLayout.disk_paths(info)
  end

  @spec delete_data!(Torrent.hash()) :: :ok
  def delete_data!(hash) do
    hash
    |> data_paths()
    |> delete_paths!()
  end

  @spec delete_paths!([Path.t()]) :: :ok
  def delete_paths!(paths) do
    Enum.each(paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise "failed to delete #{path}: #{inspect(reason)}"
      end
    end)

    paths
    |> Enum.map(&Path.dirname/1)
    |> Enum.reduce(MapSet.new(), &include_parent_dirs/2)
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.each(&remove_empty_dir/1)

    :ok
  end

  @spec include_parent_dirs(Path.t(), MapSet.t()) :: MapSet.t()
  defp include_parent_dirs(dir, acc) do
    cwd = File.cwd!()
    parent = Path.dirname(dir)

    cond do
      dir == cwd ->
        acc

      parent == dir ->
        MapSet.put(acc, dir)

      true ->
        include_parent_dirs(parent, MapSet.put(acc, dir))
    end
  end

  @spec remove_empty_dir(Path.t()) :: :ok
  defp remove_empty_dir(dir) do
    case File.ls(dir) do
      {:ok, []} -> File.rmdir(dir)
      _ -> :ok
    end
  end
end

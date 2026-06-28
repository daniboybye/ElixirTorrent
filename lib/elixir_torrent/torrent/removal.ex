defmodule Torrent.Removal do
  @moduledoc false

  alias Torrent.{Model, PathLayout}

  @spec data_paths(Torrent.hash()) :: [Path.t()]
  def data_paths(hash) do
    hash
    |> Model.get()
    |> disk_paths()
  end

  @spec download_root(Torrent.hash()) :: Path.t()
  def download_root(hash) do
    hash
    |> Model.get()
    |> download_root_for()
  end

  @spec disk_paths(Torrent.t()) :: [Path.t()]
  def disk_paths(%Torrent{metadata: %{"info" => info}} = torrent) do
    PathLayout.disk_paths(info, download_root_for(torrent))
  end

  @spec delete_data!(Torrent.hash()) :: :ok
  def delete_data!(hash) do
    torrent = Model.get(hash)
    delete_paths!(disk_paths(torrent), download_root_for(torrent))
  end

  @spec delete_paths!([Path.t()], Path.t()) :: :ok
  def delete_paths!(paths, download_root \\ File.cwd!()) do
    Enum.each(paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> raise "failed to delete #{path}: #{inspect(reason)}"
      end
    end)

    paths
    |> Enum.map(&Path.dirname/1)
    |> Enum.reduce(MapSet.new(), &include_parent_dirs(&1, &2, download_root))
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.each(&remove_empty_dir/1)

    :ok
  end

  @spec download_root_for(Torrent.t()) :: Path.t()
  defp download_root_for(%Torrent{download_dir: dir}) when is_binary(dir), do: dir
  defp download_root_for(_), do: File.cwd!()

  @spec include_parent_dirs(Path.t(), MapSet.t(), Path.t()) :: MapSet.t()
  defp include_parent_dirs(dir, acc, root) do
    parent = Path.dirname(dir)

    cond do
      dir == root ->
        acc

      parent == dir ->
        MapSet.put(acc, dir)

      true ->
        include_parent_dirs(parent, MapSet.put(acc, dir), root)
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

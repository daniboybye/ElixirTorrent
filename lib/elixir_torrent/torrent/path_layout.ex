defmodule Torrent.PathLayout do
  @moduledoc false

  @type info :: map()

  @doc """
  Returns on-disk paths for all files described by a torrent info dictionary.
  """
  @spec disk_paths(info(), Path.t()) :: [Path.t()]
  def disk_paths(info, cwd \\ File.cwd!()) when is_map(info) do
    case info do
      %{"length" => _, "name" => name} ->
        [Path.join(cwd, sanitize_name(name))]

      %{"files" => files} ->
        Enum.map(files, fn %{"path" => path} ->
          Path.join([cwd | layout_path(info, path)])
        end)
    end
  end

  @doc """
  Returns the relative path (under the download root) for a file path list.
  """
  @spec relative_path(info(), [String.t()]) :: String.t()
  def relative_path(info, path) when is_map(info) and is_list(path) do
    info
    |> layout_path(path)
    |> Path.join()
  end

  @doc """
  Returns path components (under the download root) for a file path list.
  """
  @spec layout_path(info(), [String.t()]) :: [String.t()]
  def layout_path(info, path) when is_map(info) and is_list(path) do
    case info do
      %{"length" => _, "name" => name} ->
        [sanitize_name(name)]

      %{"files" => files, "name" => name} ->
        if wrap_loose_files?(files) do
          [sanitize_name(name) | path]
        else
          path
        end
    end
  end

  @spec wrap_loose_files?([map()]) :: boolean()
  defp wrap_loose_files?(files) do
    files
    |> Enum.map(fn %{"path" => [first | _]} -> first end)
    |> Enum.uniq()
    |> then(&(length(&1) >= 2))
  end

  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) when is_binary(name) do
    name
    |> String.replace(~r|[/\\]|, "_")
    |> String.replace(<<0>>, "")
    |> case do
      "" -> "download"
      sanitized -> sanitized
    end
  end
end

defmodule Torrent.Files do
  @moduledoc """
  Lists files in a torrent with per-file download progress.

  Progress is derived from the torrent bitfield at piece granularity: a byte
  range counts as downloaded only when every piece overlapping that range is
  marked complete in the bitfield.
  """

  alias Torrent.Bitfield
  alias Torrent.Model
  alias Torrent.PathLayout

  defmodule Entry do
    @enforce_keys [:index, :path, :name, :length, :downloaded, :progress, :complete?]
    defstruct [:index, :path, :name, :length, :downloaded, :progress, :complete?]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            path: String.t(),
            name: String.t(),
            length: non_neg_integer(),
            downloaded: non_neg_integer(),
            progress: float(),
            complete?: boolean()
          }
  end

  @spec list(Torrent.hash()) :: [Entry.t()]
  def list(hash) do
    hash
    |> Model.get()
    |> build_entries()
  end

  @spec count(Torrent.hash()) :: non_neg_integer()
  def count(hash) do
    hash
    |> Model.get()
    |> file_specs()
    |> length()
  end

  @doc false
  @spec build_entries(Torrent.t()) :: [Entry.t()]
  def build_entries(%Torrent{} = torrent) do
    piece_length = torrent.metadata["info"]["piece length"]

    torrent
    |> file_specs()
    |> Enum.with_index()
    |> Enum.map(fn {file, index} ->
      downloaded =
        count_downloaded_in_range(
          file.offset,
          file.offset + file.length,
          torrent.bitfield,
          piece_length,
          torrent.last_index,
          torrent.last_piece_length
        )

      %Entry{
        index: index,
        path: file.path,
        name: file.name,
        length: file.length,
        downloaded: downloaded,
        progress: progress_percent(downloaded, file.length),
        complete?: downloaded >= file.length
      }
    end)
  end

  @spec file_specs(Torrent.t()) :: [
          %{offset: non_neg_integer(), length: pos_integer(), path: String.t(), name: String.t()}
        ]
  defp file_specs(%Torrent{metadata: %{"info" => info}}) do
    normalize_files(info)
  end

  @spec normalize_files(map()) :: [
          %{offset: non_neg_integer(), length: pos_integer(), path: String.t(), name: String.t()}
        ]
  defp normalize_files(%{"length" => length, "name" => name}) do
    sanitized = PathLayout.sanitize_name(name)
    [%{offset: 0, length: length, path: sanitized, name: sanitized}]
  end

  defp normalize_files(%{"files" => files} = info) do
    {_, entries} =
      Enum.reduce(files, {0, []}, fn %{"length" => length, "path" => path}, {offset, acc} ->
        path_str = PathLayout.relative_path(info, path)
        name = List.last(path)
        entry = %{offset: offset, length: length, path: path_str, name: name}
        {offset + length, [entry | acc]}
      end)

    Enum.reverse(entries)
  end

  @spec progress_percent(non_neg_integer(), non_neg_integer()) :: float()
  defp progress_percent(_downloaded, 0), do: 100.0

  defp progress_percent(downloaded, length) when length > 0 do
    downloaded * 100.0 / length
  end

  @spec count_downloaded_in_range(
          non_neg_integer(),
          non_neg_integer(),
          Torrent.bitfield(),
          pos_integer(),
          Torrent.index(),
          Torrent.length()
        ) :: non_neg_integer()
  defp count_downloaded_in_range(
         start_byte,
         end_byte,
         bitfield,
         piece_length,
         last_index,
         last_piece_length
       ) do
    Enum.reduce(0..last_index, 0, fn index, acc ->
      piece_start = index * piece_length

      piece_size =
        if index == last_index, do: last_piece_length, else: piece_length

      piece_end = piece_start + piece_size - 1
      overlap_start = max(start_byte, piece_start)
      overlap_end = min(end_byte - 1, piece_end)

      if overlap_start <= overlap_end and Bitfield.have?(bitfield, index) do
        acc + (overlap_end - overlap_start + 1)
      else
        acc
      end
    end)
  end
end

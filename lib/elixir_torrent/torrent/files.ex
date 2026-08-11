defmodule Torrent.Files do
  @moduledoc """
  Lists files in a torrent with per-file download progress.

  Progress is derived from the torrent bitfield at piece granularity: a byte
  range counts as downloaded only when every piece overlapping that range is
  marked complete in the bitfield.

  BEP 47 padding files (marked with `attr` containing `"p"`) are excluded
  from user-facing listings: they exist only to align the following real
  file to a piece boundary and their bytes are known-zero. They still
  occupy their share of the flat piece stream so per-piece offset math
  keeps working; only the visible file list drops them.
  """

  alias Torrent.{Bitfield, Merkle, Model, PathLayout}

  @doc """
  Whether a file entry from `info["files"]` is a BEP 47 padding file.

  BEP 47 § File attributes: the `attr` field is a byte string of one-letter
  flags; `p` marks the file as padding. Real files never carry this flag,
  so a padding file always has both `attr` and `p` in it.
  """
  @spec padding?(map()) :: boolean()
  def padding?(%{"attr" => attr}) when is_binary(attr), do: String.contains?(attr, "p")
  def padding?(_), do: false

  defmodule Entry do
    @moduledoc """
    One user-visible file row with download progress for the WebUI file list.
    """

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
          torrent.last_piece_length,
          torrent.piece_lengths
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
  defp file_specs(%Torrent{kind: :v2, merkle: merkle, metadata: %{"info" => info}})
       when is_map(merkle) do
    {:ok, layout} = Merkle.piece_stream_layout(merkle)

    layout.all_files
    |> Enum.flat_map(fn
      {_end_offset, {:gap, _gap_len}} ->
        []

      {end_offset, {:file, file, _relative}} ->
        offset = end_offset - file.length

        [
          %{
            offset: offset,
            length: file.length,
            path: PathLayout.relative_path(info, file.path),
            name: List.last(file.path)
          }
        ]
    end)
  end

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
      Enum.reduce(files, {0, []}, fn file, {offset, acc} ->
        %{"length" => length, "path" => path} = file
        next_offset = offset + length

        if padding?(file) do
          # Advance the running byte offset so following real files land at
          # their true positions in the piece stream, but do not surface a
          # user-visible entry for the pad.
          {next_offset, acc}
        else
          path_str = PathLayout.relative_path(info, path)
          name = List.last(path)
          entry = %{offset: offset, length: length, path: path_str, name: name}
          {next_offset, [entry | acc]}
        end
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
          Torrent.length(),
          [pos_integer()] | nil
        ) :: non_neg_integer()
  defp count_downloaded_in_range(
         start_byte,
         end_byte,
         bitfield,
         piece_length,
         last_index,
         last_piece_length,
         piece_lengths
       ) do
    Enum.reduce(0..last_index, 0, fn index, acc ->
      piece_start = index * piece_length

      piece_size =
        piece_size_at(index, piece_length, last_index, last_piece_length, piece_lengths)

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

  defp piece_size_at(index, _piece_length, last_index, last_piece_length, lengths)
       when is_list(lengths) and index == last_index,
       do: last_piece_length

  defp piece_size_at(index, _piece_length, _last_index, _last_piece_length, lengths)
       when is_list(lengths),
       do: Enum.at(lengths, index)

  defp piece_size_at(index, piece_length, last_index, last_piece_length, _piece_lengths) do
    if index == last_index, do: last_piece_length, else: piece_length
  end
end

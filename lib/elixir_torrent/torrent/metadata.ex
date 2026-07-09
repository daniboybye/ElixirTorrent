defmodule Torrent.Metadata do
  @moduledoc false

  @doc """
  Whether this torrent can serve BEP 9 metadata (completed download with known info dict).
  """
  @spec serve?(Torrent.hash()) :: boolean()
  def serve?(hash) do
    case Torrent.get(hash, [:left, :metadata]) do
      [0, %{"info" => info}] when is_map(info) -> true
      _ -> false
    end
  end

  @doc """
  Bencoded info dictionary bytes transferred by BEP 9 ut_metadata.
  """
  @spec info_blob(Torrent.hash()) :: binary() | nil
  def info_blob(hash) do
    case Torrent.get(hash, :metadata) do
      %{"info" => info} when is_map(info) -> Bento.encode!(info)
      _ -> nil
    end
  end

  @spec metadata_size(Torrent.hash()) :: pos_integer() | nil
  def metadata_size(hash) do
    case info_blob(hash) do
      blob when is_binary(blob) and byte_size(blob) > 0 -> byte_size(blob)
      _ -> nil
    end
  end
end

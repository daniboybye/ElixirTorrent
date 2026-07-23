defmodule Torrent.Metadata do
  @moduledoc false

  @doc """
  Whether this torrent can serve BEP 9 metadata (completed download with known info dict).
  """
  @spec serve?(Torrent.hash()) :: boolean()
  def serve?(hash) do
    case Torrent.get(hash, [:left, :info_blob]) do
      [0, blob] when is_binary(blob) -> true
      _ -> false
    end
  end

  @doc """
  Bencoded info dictionary bytes transferred by BEP 9 ut_metadata.

  Returns the raw slice captured at parse time — never a re-encoded map — so the
  SHA-1 of the returned bytes matches the torrent's info_hash (BEP 3).
  """
  @spec info_blob(Torrent.hash()) :: binary() | nil
  def info_blob(hash) do
    case Torrent.get(hash, :info_blob) do
      blob when is_binary(blob) -> blob
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

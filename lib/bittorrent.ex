defmodule Bittorrent do
  defdelegate download(path, options \\ []), to: Torrents

  def get(pid) do
    Torrent.get_hash(pid)
    |> Torrent.get()
  end
end

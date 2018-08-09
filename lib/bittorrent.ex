defmodule Bittorrent do
  defdelegate download(file_name), to: Torrents
end

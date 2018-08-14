defmodule Bittorrent do
  defdelegate download(path, options \\ []), to: Torrents
end

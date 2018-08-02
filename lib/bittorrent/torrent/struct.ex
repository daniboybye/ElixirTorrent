defmodule Bittorent.Torrent.Struct do
  @enforce_keys [:hash, :struct, :bytes,:pieces_count]
  defstruct [:hash, :struct, :bytes,
   uploaded: 0, downloaded: 0, status: "started",
   :pieces_count]
end
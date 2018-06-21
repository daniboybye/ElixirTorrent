defmodule Bittorent.Torrent.Struct do
  defstruct [info_hash: nil, struct: nil, 
  bytes: nil, uploaded: nil, downloaded: nil, status: nil,
  pieces_size: nil,
  bitfield: nil]
end
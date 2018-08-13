defmodule Torrent.Downloads.Piece.Request do
  @enforce_keys [:peer_id, :subpiece]
  defstruct [:peer_id, :subpiece, ref: nil, timer: nil]
end

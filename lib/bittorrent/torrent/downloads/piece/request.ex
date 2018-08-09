defmodule Torrent.Downloads.Piece.Request do
  @enforce_keys [:peer_id, :ref, :timer, :subpiece]
  defstruct [:peer_id, :ref, :timer, :subpiece]
end

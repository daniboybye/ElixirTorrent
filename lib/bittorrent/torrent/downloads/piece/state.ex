defmodule Torrent.Downloads.Piece.State do
  @enforce_keys [:index, :hash, :waiting]
  defstruct [:index, :hash, :waiting, :timer, requests: []]
end

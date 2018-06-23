defmodule Bittorrent.Peer.Controller.State do
  defstruct[:peer_id,:transmitter,:bitfield,:piece_size,:torrent]
end
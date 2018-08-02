defmodule Bittorrent.Peer.Controller.State do
  @enforce_keys [:key]
  defstruct[:key,bitfield: nil,interested: false, choke: true,
  interested_of_me: false, choke_me: true,piece: nil]
end
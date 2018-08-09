defmodule Peer.Controller.State do
  @enforce_keys [:key, :status, :pieces_count]
  defstruct [
    :key,
    :status,
    :pieces_count,
    requests: [],
    rank: 0,
    bitfield: nil,
    interested: false,
    choke: true,
    interested_of_me: false,
    choke_me: true
  ]
end

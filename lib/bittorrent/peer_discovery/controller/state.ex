defmodule PeerDiscovery.Controller.State do
  defstruct peers: %{}, requests: %{}

  @type key :: Torrent.hash() | {Torrent.hash(), atom()}

  @type t :: %__MODULE__{
          peers: %{required(Tracker.announce()) => %{required(Torrent.hash()) => list(Peer.t())}},
          requests: %{required(reference()) => {Tracker.announce(), key()}}
        }
end

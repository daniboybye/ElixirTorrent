defmodule PeerDiscovery.Controller.State do
  defstruct dictionary: %{}, requests: %{}

  @type key :: Torrent.hash() | {Torrent.hash(), atom()}

  @type t :: %__MODULE__{
          dictionary: map(), # map(hash => %{tiers: tiers, peers: peers})
          requests: %{required(reference()) => {Tracker.announce(), key()}}
        }
end

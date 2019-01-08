defmodule PeerDiscovery.Controller.State do
  defstruct dictionary: %{}, requests: %{}

  @type key :: Torrent.hash() | {Torrent.hash(), atom()}

  @type t :: %__MODULE__{
          # map(hash => %{tiers: tiers, peers: peers})
          dictionary: map(),
          requests: %{required(reference()) => {Tracker.announce(), key()}}
        }
end

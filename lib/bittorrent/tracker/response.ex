defmodule Tracker.Response do
  @enforce_keys [:interval, :peers, :complete, :incomplete]
  defstruct [:interval, :peers, :complete, :incomplete, external_ip: nil]

  @type t :: %__MODULE__{
          # in seconds
          interval: non_neg_integer(),
          peers: list(Peer.t()),
          complete: non_neg_integer(),
          incomplete: non_neg_integer()
        }
end

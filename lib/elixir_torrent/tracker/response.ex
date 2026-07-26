defmodule Tracker.Response do
  @moduledoc """
  Normalized HTTP/UDP tracker announce response (interval, peers, swarm counts).
  """

  @enforce_keys [:interval, :peers, :complete, :incomplete]
  defstruct [:interval, :peers, :complete, :incomplete, external_ip: nil, min_interval: nil]

  @type t :: %__MODULE__{
          # in seconds
          interval: non_neg_integer(),
          min_interval: non_neg_integer() | nil,
          peers: list(Peer.t()),
          complete: non_neg_integer(),
          incomplete: non_neg_integer()
        }
end

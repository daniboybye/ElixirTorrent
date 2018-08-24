defmodule PeerDiscovery.ConnectionIds.State do
  defstruct ids: %{}, requests: %{}

  @type t :: %__MODULE__{
          ids: %{required(Tracker.announce()) => Tracker.connection_id() | list(GenServer.from())},
          requests: %{required(reference()) => Tracker.announce()}
        }
end

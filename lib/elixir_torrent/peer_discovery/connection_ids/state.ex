defmodule PeerDiscovery.ConnectionIds.State do
  defstruct ids: %{}, requests: %{}

  @type t :: %__MODULE__{
          ids: map(), #{ip, port} => connection_id | list(GenServer.from)

          requests: map() # ref => {ip, port}
        }
end

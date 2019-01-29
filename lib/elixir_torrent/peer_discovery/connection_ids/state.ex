defmodule PeerDiscovery.ConnectionIds.State do
  defstruct ids: %{}, requests: %{}

  @type t :: %__MODULE__{
          # {ip, port} => connection_id | list(GenServer.from)
          ids: map(),
          # ref => {ip, port}
          requests: map()
        }
end

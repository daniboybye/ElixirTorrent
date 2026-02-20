defmodule PeerDiscovery.ConnectionIds.State do
  defstruct ids: %{}, requests: %{}

  @type t :: %__MODULE__{
          # {tracker_ip, tracker_port, local_udp_port} => connection_id | list(GenServer.from)
          ids: map(),
          # ref => {tracker_ip, tracker_port, local_udp_port}
          requests: map()
        }
end

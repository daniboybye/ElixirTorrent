defmodule Bittorent.PeerDiscovery.State do
  @doc """
    peers: %{info_hash => [peer]}
    requests: %{ref => from}
  """
  @enforce_keys [:port,:peer_id]
  defstruct [:port, :peer_id, peers: %{}, requests: %{}]
end
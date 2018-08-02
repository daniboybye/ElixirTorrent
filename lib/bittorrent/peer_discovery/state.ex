defmodule Bittorent.PeerDiscovery.State do
  @doc """
    peers: %{hash => [peer]}
    requests: %{ref => from}
  """
  defstruct [peers: %{}, requests: %{}]
end
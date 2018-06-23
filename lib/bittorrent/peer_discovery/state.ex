defmodule Bittorent.PeerDiscovery.State do
  @doc """
    peers: %{info_hash => [peer]}
    requests: %{ref => from}
  """
  defstruct [peers: %{}, requests: %{}]
end
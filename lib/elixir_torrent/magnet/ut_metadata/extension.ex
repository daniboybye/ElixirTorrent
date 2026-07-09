defmodule Magnet.UtMetadata.Extension do
  @moduledoc false

  @behaviour Peer.LTEP.Extension

  # BEP 9 extension name in the BEP 10 `m` dictionary.
  @impl true
  def name, do: "ut_metadata"

  # Local id assigned in our outbound handshake; peers use this when sending to us.
  @impl true
  def local_id, do: 1

  # Magnet leech path: we do not yet know metadata size (BEP 9 § extension header).
  @impl true
  def outbound_fields, do: %{}
end

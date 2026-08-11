defmodule Magnet.UtMetadata.Extension do
  @moduledoc false

  @behaviour Peer.LTEP.Extension

  # BEP 9 extension name in the BEP 10 `m` dictionary.
  @impl Peer.LTEP.Extension
  def name, do: "ut_metadata"

  # Local id assigned in our outbound handshake; peers use this when sending to us.
  @impl Peer.LTEP.Extension
  def local_id, do: 1

  # Magnet leech path: we do not yet know metadata size (BEP 9 § extension header).
  @impl Peer.LTEP.Extension
  def outbound_fields, do: %{}
end

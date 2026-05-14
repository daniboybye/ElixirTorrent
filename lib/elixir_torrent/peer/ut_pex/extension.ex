defmodule Peer.UtPex.Extension do
  @moduledoc false

  @behaviour Peer.LTEP.Extension

  # BEP 11 extension name in the BEP 10 `m` dictionary.
  @impl Peer.LTEP.Extension
  def name, do: "ut_pex"

  @impl Peer.LTEP.Extension
  def local_id, do: 2

  @impl Peer.LTEP.Extension
  def outbound_fields, do: %{}
end

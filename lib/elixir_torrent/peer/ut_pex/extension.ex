defmodule Peer.UtPex.Extension do
  @moduledoc false

  @behaviour Peer.LTEP.Extension

  # BEP 11 extension name in the BEP 10 `m` dictionary.
  @impl true
  def name, do: "ut_pex"

  @impl true
  def local_id, do: 2

  @impl true
  def outbound_fields, do: %{}
end

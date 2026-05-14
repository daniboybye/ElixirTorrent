defmodule Peer.UtHolepunch.Extension do
  @moduledoc false

  @behaviour Peer.LTEP.Extension

  @impl Peer.LTEP.Extension
  def name, do: "ut_holepunch"

  @impl Peer.LTEP.Extension
  def local_id, do: 3

  @impl Peer.LTEP.Extension
  def outbound_fields, do: %{}
end

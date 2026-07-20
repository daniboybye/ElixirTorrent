defmodule Peer.UtHolepunch.Extension do
  @moduledoc false

  @behaviour Peer.LTEP.Extension

  @impl true
  def name, do: "ut_holepunch"

  @impl true
  def local_id, do: 3

  @impl true
  def outbound_fields, do: %{}
end

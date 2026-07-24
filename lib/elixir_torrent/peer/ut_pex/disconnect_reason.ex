defmodule Peer.UtPex.DisconnectReason do
  @moduledoc """
  Maps peer disconnect reasons to BEP 11 recent-list eligibility.

  Only fully handshaken peers disconnected for policy reasons that BEP 11 treats as
  safe to re-advertise briefly may enter the recent cache:

  - `{:shutdown, :duplicate_peer}` — same peer id on another address family
  - `{:shutdown, :no_mutual_interest}` — bitfields exchanged, neither side interested
  - `{:shutdown, :resource_limit}` — swarm cap / max peer slots

  Ineligible (never cached): protocol errors, timeouts, remote closes, churn backoff,
  malicious bans, generic `:normal` / app shutdown, and handoffs that never completed LTEP.
  """

  alias Peer.Controller.State

  @eligible_reasons [
    {:shutdown, :duplicate_peer},
    {:shutdown, :no_mutual_interest},
    {:shutdown, :resource_limit}
  ]

  @doc false
  @spec eligible?(term()) :: boolean()
  def eligible?(reason), do: reason in @eligible_reasons

  @doc false
  @spec handshaken?(State.t()) :: boolean()
  def handshaken?(%State{
        connected_at: at,
        peer_reserved: nil,
        downloaded_at_connect: nil
      })
      when is_integer(at),
      do: true

  def handshaken?(_), do: false

  @doc false
  @spec eligible_reasons() :: [term()]
  def eligible_reasons, do: @eligible_reasons
end

defmodule Peer.LTEP.Extension do
  @moduledoc """
  Behaviour for BitTorrent LTEP extensions (BEP 10).

  Each extension registers a unique wire name (typically prefixed, e.g. `ut_metadata`)
  and the local message id we assign in our outbound handshake `m` dictionary. Peers
  use that id when sending extension messages *to us*; we use the id they advertise
  when sending *to them* (BEP 10 § handshake message / `m`).
  """

  @doc """
  Extension name as it appears in the handshake `m` dictionary (case sensitive).
  """
  @callback name() :: String.t()

  @doc """
  Local extension message id we assign in our outbound handshake.

  Must be unique among extensions registered on the same session and must not be 0
  (0 means disabled in a peer's handshake, not a valid outbound assignment).
  """
  @callback local_id() :: pos_integer()

  @doc """
  Optional top-level handshake dictionary keys beyond `m` (e.g. BEP 9 `metadata_size`).
  """
  @callback outbound_fields() :: map()

  @optional_callbacks outbound_fields: 0

  @doc false
  def name(module) when is_atom(module), do: module.name()

  @doc false
  def local_id(module) when is_atom(module), do: module.local_id()

  @doc false
  def outbound_fields(module) when is_atom(module) do
    if function_exported?(module, :outbound_fields, 0) do
      module.outbound_fields()
    else
      %{}
    end
  end
end

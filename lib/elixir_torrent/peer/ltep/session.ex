defmodule Peer.LTEP.Session do
  @moduledoc """
  Per-connection BEP 10 extension protocol state.

  Tracks the local `m` ids we advertise (used by the peer when sending to us) and
  the merged peer handshake (ids we use when sending to the peer). Extension modules
  register through `Peer.LTEP.Extensions` (BEP 10 § rationale — per-peer ids).
  """

  alias Peer.LTEP.{Extension, Handshake}

  defstruct local_m: %{},
            peer: %Handshake{},
            extensions: []

  @type t :: %__MODULE__{
          local_m: %{String.t() => pos_integer()},
          peer: Handshake.t(),
          extensions: [module()]
        }

  @doc """
  Builds a fresh session from registered LTEP extension modules.

  Each module's `local_id/0` must be unique; ids are stored in `local_m` for our
  outbound handshake.
  """
  @spec new([module()]) :: t()
  def new(extensions \\ Peer.LTEP.Extensions.all()) do
    local_m =
      extensions
      |> Enum.map(fn mod -> {Extension.name(mod), Extension.local_id(mod)} end)
      |> Map.new()

    %__MODULE__{local_m: local_m, extensions: extensions}
  end

  @doc """
  Encodes our outbound extension handshake (BEP 10 § handshake message).

  Includes `m`, client version `v`, and any extension-specific top-level keys.
  """
  @spec outbound_handshake(t(), keyword()) :: binary()
  def outbound_handshake(%__MODULE__{} = session, opts \\ []) do
    client_version = Keyword.get(opts, :client_version, default_client_version())

    extra_fields =
      session.extensions
      |> Enum.map(&Extension.outbound_fields/1)
      |> Enum.reduce(%{}, &Map.merge/2)
      |> Map.merge(Keyword.get(opts, :extra_fields, %{}))

    base =
      %Handshake{m: session.local_m, v: client_version}
      |> Handshake.to_map()
      |> Map.merge(address_fields())
      |> Map.merge(extra_fields)

    base |> Handshake.from_map() |> Handshake.encode()
  end

  @doc false
  @spec address_fields() :: map()
  def address_fields do
    port = Acceptor.port()

    %{}
    |> maybe_address("p", port, is_integer(port))
    |> maybe_address("ipv4", Acceptor.ipv4_binary(), is_binary(Acceptor.ipv4_binary()))
    |> maybe_address("ipv6", Acceptor.ipv6_binary(), is_binary(Acceptor.ipv6_binary()))
  end

  @spec maybe_address(map(), String.t(), term(), boolean()) :: map()
  defp maybe_address(map, _key, _value, false), do: map
  defp maybe_address(map, key, value, true), do: Map.put(map, key, value)

  @doc """
  Applies a peer handshake dictionary, merging on re-handshake (BEP 10).
  """
  @spec apply_peer_handshake(t(), Handshake.t()) :: t()
  def apply_peer_handshake(%__MODULE__{} = session, %Handshake{} = incoming) do
    peer = Handshake.merge(session.peer, incoming)
    %{session | peer: peer}
  end

  @doc """
  Extension message id to use when sending *to* the peer (from their handshake `m`).
  """
  @spec peer_extension_id(t(), String.t()) :: pos_integer() | nil
  def peer_extension_id(%__MODULE__{} = session, name) do
    Handshake.peer_extension_id(session.peer, name)
  end

  @doc """
  Extension message id the peer must use when sending *to* us (from our `local_m`).
  """
  @spec local_extension_id(t(), String.t()) :: pos_integer() | nil
  def local_extension_id(%__MODULE__{local_m: local_m}, name) when is_binary(name) do
    case Map.get(local_m, name) do
      id when is_integer(id) and id > 0 -> id
      _ -> nil
    end
  end

  @doc """
  Whether the peer advertises support for the named extension.
  """
  @spec peer_supports?(t(), String.t()) :: boolean()
  def peer_supports?(session, name), do: Handshake.peer_supports?(session.peer, name)

  @doc """
  Returns the peer handshake struct (listen port, client version, metadata_size, etc.).
  """
  @spec peer_handshake(t()) :: Handshake.t()
  def peer_handshake(%__MODULE__{peer: peer}), do: peer

  @spec default_client_version() :: String.t()
  defp default_client_version do
    "ElixirTorrent #{ElixirTorrent.version()}"
  end
end

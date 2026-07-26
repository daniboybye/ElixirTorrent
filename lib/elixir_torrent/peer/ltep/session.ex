defmodule Peer.LTEP.Session do
  @moduledoc """
  Per-connection BEP 10 extension protocol state.

  Tracks the local `m` ids we advertise (used by the peer when sending to us) and
  the merged peer handshake (ids we use when sending to the peer). Extension modules
  register through `Peer.LTEP.Extensions` (BEP 10 § rationale — per-peer ids).
  """

  alias Peer.LTEP.{Extension, Extensions, Handshake}

  # BEP 10 `reqq`: how many pending `request` messages *from* the peer we accept
  # without dropping. Torrent.Uploader spawns a Task per request (no internal cap),
  # so this is a courtesy advertisement, not an enforced limit. 500 matches
  # qBittorrent's default; libtorrent uses 250. Peers that respect it will keep
  # deeper request pipelines to us → better upload throughput on high-BDP links.
  @local_reqq 500

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
  def new(extensions \\ Extensions.all()) do
    registrations =
      extensions
      |> Enum.map(fn mod -> {Extension.name(mod), Extension.local_id(mod)} end)

    validate_registrations!(registrations)

    %__MODULE__{local_m: Map.new(registrations), extensions: extensions}
  end

  @doc """
  Encodes our outbound extension handshake (BEP 10 § handshake message).

  Includes `m`, client version `v`, our accepted `reqq` (BEP 10 queue depth),
  listen `p`/`ipv4`/`ipv6`, and any extension-specific top-level keys.
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
      %Handshake{m: session.local_m, v: client_version, reqq: @local_reqq, e: 1}
      |> Handshake.to_map()
      |> Map.merge(address_fields())
      |> Map.merge(extra_fields)

    base |> Handshake.from_map() |> Handshake.encode()
  end

  @doc """
  Our advertised BEP 10 `reqq` (accepted inbound `request` queue depth).
  """
  @spec local_reqq() :: pos_integer()
  def local_reqq, do: @local_reqq

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

  @spec validate_registrations!([{term(), term()}]) :: :ok
  defp validate_registrations!(registrations) do
    Enum.each(registrations, fn
      {name, id} when is_binary(name) and name != "" and id in 1..255 ->
        :ok

      registration ->
        raise ArgumentError,
              "invalid LTEP extension registration #{inspect(registration)}; " <>
                "names must be non-empty binaries and local ids must be in 1..255"
    end)

    ensure_unique!(registrations, 0, "names")
    ensure_unique!(registrations, 1, "local ids")
  end

  @spec ensure_unique!([{term(), term()}], 0 | 1, String.t()) :: :ok
  defp ensure_unique!(registrations, position, label) do
    values = Enum.map(registrations, &elem(&1, position))

    if MapSet.size(MapSet.new(values)) != length(values) do
      raise ArgumentError, "LTEP extension #{label} must be unique: #{inspect(values)}"
    end

    :ok
  end
end

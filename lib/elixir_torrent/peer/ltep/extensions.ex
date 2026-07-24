defmodule Peer.LTEP.Extensions do
  @moduledoc """
  Registry of LTEP extension modules wired into magnet / peer sessions.

  Add new behaviours here (e.g. `ut_pex` / BEP 11) without changing the core
  BEP 10 framing code.
  """

  @doc """
  Extension modules active for magnet metadata connections and completed-torrent peers.
  """
  @spec all() :: [module()]
  def all, do: [Peer.UtPex.Extension, Magnet.UtMetadata.Extension]

  @doc """
  LTEP extensions to advertise on a normal peer connection for `hash`.
  """
  @spec for_peer(Torrent.hash()) :: [module()]
  def for_peer(hash) do
    pex = if Peer.UtPex.allowed?(hash), do: [Peer.UtPex.Extension], else: []
    [Peer.UtHolepunch.Extension | pex ++ metadata_extensions(hash)]
  end

  @doc """
  LTEP extensions for a direct BEP 9 metadata connection.

  Advertises `ut_pex` only when inbound PEX can be consumed (magnet bootstrap
  `ConnectionManager` is up) and the torrent is not known private (BEP 27).
  """
  @spec for_magnet(Torrent.hash()) :: [module()]
  def for_magnet(hash) when is_binary(hash) and byte_size(hash) == 20 do
    extensions = [Magnet.UtMetadata.Extension]

    if Peer.UtPex.allowed?(hash) and Magnet.Connection.pex_consumer_active?(hash) do
      [Peer.UtPex.Extension | extensions]
    else
      extensions
    end
  end

  @spec metadata_extensions(Torrent.hash()) :: [module()]
  defp metadata_extensions(hash) do
    cond do
      Torrent.Metadata.serve?(hash) -> [Magnet.UtMetadata.Extension]
      Magnet.Bootstrap.active?(hash) -> [Magnet.UtMetadata.Extension]
      true -> []
    end
  end
end

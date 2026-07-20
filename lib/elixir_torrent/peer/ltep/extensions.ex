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
  def all, do: [Peer.UtHolepunch.Extension, Peer.UtPex.Extension, Magnet.UtMetadata.Extension]

  @doc """
  LTEP extensions to advertise on a normal peer connection for `hash`.
  """
  @spec for_peer(Torrent.hash()) :: [module()]
  def for_peer(hash) do
    [Peer.UtHolepunch.Extension, Peer.UtPex.Extension | metadata_extensions(hash)]
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

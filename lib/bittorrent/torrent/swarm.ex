defmodule Bittorrent.Torrent.Swarm do
  import Bittorrent
  require Via

  Via.make()

  @doc """
  key = hash 
  """

  def start_link(key) do
    DynamicSupervisor.start_link(
      name: via(key),
      strategy: :one_for_one,
      max_restarts: 0
    )
  end

  def interested(key, index) do
    DynamicSupervisor.which_children(via(key))
    |> Enum.each(&Peer.interested(&1, index))
  end

  def broadcast_have(key, index) do
    DynamicSupervisor.which_children(via(key))
    |> Enum.each(&Peer.have(&1, index))
  end

  def add_peer(hash,peer_id,socket) do
    child = {Peer, {{peer_id,hash},socket}}
    DynamicSupervisor.start_child(via(hash), child)
  end

  def download(key, index) do
end
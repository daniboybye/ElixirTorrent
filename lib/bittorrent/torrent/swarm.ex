defmodule Bittorrent.Torrent.Swarm do
  use DynamicSupervisor, type: :supervisor

  import Bittorrent
  require Via

  Via.make()

  @doc """
  key = info_hash 
  """

  def start_link(key) do
    DynamicSupervisor.start_child(__MODULE__, nil, name: vie(key))
  end

  def add_peer(info_hash,peer_id,socket) do
    via(info_hash)
    |> DynamicSupervisor.start_child({{peer_id,info_hash},socket})
  end

  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 0)
  end
end
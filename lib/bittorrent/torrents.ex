defmodule Bittorent.Torrents do
  import Bittorent

  def start_link() do
    DynamicSupervisor.start_link(
      strategy: :one_for_one, 
      max_restarts: 0,
      name: __MODULE__
    )
  end

  def start_torrent(torrent) do
    Dynamicsupervisor.start_child(__MODULE__,{Torrent, torrent})
  end
end
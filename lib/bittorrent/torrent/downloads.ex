defmodule Bittorrent.Torrent.Downloads do
  import Bittorrent
  require Via

  Via.make()

  def start_link(hash) do
    DynamicSupervisor.start_link(
      name: via(hash), 
      strategy: :one_for_one, 
      max_restarts: :infinity
    )
  end

end
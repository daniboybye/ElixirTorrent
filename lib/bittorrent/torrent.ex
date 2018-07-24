defmodule Bittorrent.Torrent do 
  use Supervisor, type: :supervisor, restart: :transient

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init(args) do
    [
      {__MODULE__.FileHandle, args},
      {__MODULE__.Bitfield,   args},
      {__MODULE__.Swarm,      args},
      {__MODULE__.Server,     args}
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end
defmodule Bittorrent.Torrent do 
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init(args) do
    [
      {DynamicSupervisor, strategy: :one_for_one, max_restarts: 0},
      {__MODULE__.FileHandle,args}
      {__MODULE__.Server,args}
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end
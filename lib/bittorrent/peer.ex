defmodule Bittorent.Peer do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init({torrent,{socket,peer_id}}) do
    [
      {__MODULE__.Transmitter, socket},
      {__MODULE__.Receiver, socket },
      {__MODULE__.Controller, {torrent,peer_id,self()} }
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restart: 0)
  end
end
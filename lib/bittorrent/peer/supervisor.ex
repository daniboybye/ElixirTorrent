defmodule Bittorent.Peer.Supervisor do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init(args) do
    [
      {Bittorent.Peer.Transmitter, args},
      Bittorent.Peer.Controller,
      {Bittorent.Peer.Receiver, args}
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end

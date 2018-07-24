defmodule Bittorent.Peer do
  use Supervisor, restart: :temporary, type: :supervisor

  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  def init({key,_socket} = args) do
    [
      {__MODULE__.Transmitter, key},
      {__MODULE__.Sender, args},
      {__MODULE__.Controller, key},
      {__MODULE__.Receiver, args}
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restart: 0)
  end
end
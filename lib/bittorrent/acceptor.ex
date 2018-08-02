defmodule Bittorent.Acceptor do
  use Supervisor, type: :supervisor

  def start_link(), do: Supervisor.start_link(__MODULE__, nil)

  def recv(client) do
    Task.Supervisor.start_child(
      __MODULE__.Handshakes,
      Handshake, :recv, [client]
    )
  end

  def send(peer,hash) do
    Task.Supervisor.start_child(
      __MODULE__.Handshakes,
      Handshake, :send, [peer, hash]
    )
  end

  def init(_) do
    [
      {
        Tast.Supervisor, 
        name: __MODULE__.Handshakes,
        strategy: :one_for_one, 
        max_restarts: 0
      },
      __MODULE__.BlackList,
      __MODULE__.Listen
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end

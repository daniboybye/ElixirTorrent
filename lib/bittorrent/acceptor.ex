defmodule Bittorent.Acceptor do
  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, :ok)
  end

  def init(:ok) do
    [
      {Tast.Supervisor, name: __MODULE__.Handshakes}
      __MODULE__.BlackList,
      __MODULE__.Listen
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end

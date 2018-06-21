defmodule Bittorent.Acceptor.Supervisor do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  def init(args) do
    [
      {__MODULE__.BlackList},
      {__MODULE__.Listen, args}
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end

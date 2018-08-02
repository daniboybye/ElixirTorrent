defmodule Bittorent.Peer do
  use Supervisor, restart: :temporary, type: :supervisor

  import __MODULE__

  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  def have(pid, index) do
    pid
    |> Supervisor.which_children()
    |> Enum.find(&module?(&1,Sender))
    |> elem(1)
    |> Sender.have(index)
  end

  def interested(pid, index) do
    pid
    |> Supervisor.which_children()
    |> Enum.find(&module?(&1,Controller))
    |> elem(1)
    |> Controller.interested(index)
  end

  def init({key,_socket} = args) do
    [
      #{Transmitter, key},
      {Sender, args},
      {Controller, key},
      Receiver, args}
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restart: 0)
  end

  defp module?({_,_,_,[m]},module) when module === m,  do: true
  
  defp module?(_,_), do: false


end
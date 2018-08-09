defmodule Acceptor.Listen do
  use GenServer

  require Logger

  @doc """
  Listen controls a :gen_tcp.listen 
  and do not need to be closed manually
  """

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  def init(_) do
    Acceptor.port()
    |> :gen_tcp.listen(Acceptor.socket_options())
    |> case do
      {:ok, _} = x ->
        send(self(), :loop)
        x

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_info(:loop, socket), do: loop(socket)

  defp loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Logger.info("new client")
    Acceptor.Pool.give_control(client)
    Acceptor.recv(client)
    loop(socket)
  end
end

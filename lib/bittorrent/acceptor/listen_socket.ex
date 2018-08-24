defmodule Acceptor.ListenSocket do
  use GenServer, start: {__MODULE__, :start_link, []}

  require Logger

  @doc """
  ListenSocket controls a :gen_tcp.listen 
  and do not need to be closed manually
  """

  @spec start_link() :: GenServer.on_start()
  def start_link(), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec port() :: Acceptor.port_number()
  def port(), do: GenServer.call(__MODULE__, :port)

  def init(_) do
    with socket when is_port(socket) <- Enum.find_value(Acceptor.port_range(), &set_up/1) do
      Task.start_link(fn -> loop(socket) end)
      {:ok, socket}
    else
      _ ->
        {:stop, :not_free_port}
    end
  end

  def handle_call(:port, _, socket) do
    {:ok, port} = :inet.port(socket)
    {:reply, port, socket}
  end

  defp loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Logger.info("new client")
    Acceptor.Pool.give_control(client)
    Acceptor.recv(client)
    loop(socket)
  end

  defp set_up(number) do
    number
    |> :gen_tcp.listen(Acceptor.socket_options())
    |> case do
      {:ok, socket} ->
        socket

      {:error, _} ->
        nil
    end
  end
end

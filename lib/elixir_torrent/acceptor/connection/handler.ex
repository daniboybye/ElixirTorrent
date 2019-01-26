defmodule Acceptor.Connection.Handler do
  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  alias Acceptor.Connection.Handshakes
  require Logger

  @docmodule """
  ListenSocket controls a :gen_tcp.listen 
  and do not need to be closed manually
  """

  @spec port() :: :inet.port_number()
  def port(), do: GenServer.call(__MODULE__, :port)

  def init(_) do
    with {:ok, socket} <- open_listen_socket({:stop, :no_free_port}) do
      {:ok, _} = Task.start_link(fn -> loop(socket) end)
      {:ok, socket}
    end
  end

  def handle_call(:port, _, socket) do
    {:ok, port} = :inet.port(socket)
    {:reply, port, socket}
  end

  defp loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Logger.info("new client")
    Handshakes.recv(client)
    loop(socket)
  end

  defp open_listen_socket(default) do
    Enum.find_value(
      Acceptor.port_range(),
      default,
      fn number ->
        with {:error, _} <- :gen_tcp.listen(number, Acceptor.socket_options()),
             do: nil
      end
    )
  end
end

defmodule Acceptor.Connection.Handler do
  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  alias Acceptor.Connection.Handshakes
  require Logger

  @moduledoc """
  ListenSocket controls a :gen_tcp.listen
  and do not need to be closed manually
  """

  @spec port() :: :inet.port_number()
  def port(), do: GenServer.call(__MODULE__, :port)

  def init(_) do
    with {:ok, socket} <- open_listen_socket({:stop, :no_free_port}) do
      {:ok, port} = :inet.port(socket)
      Logger.info("[acceptor] listening proto=tcp port=#{port}")
      {:ok, _} = Task.start_link(fn -> loop(socket) end)
      {:ok, socket}
    end
  end

  def handle_call(:port, _, socket) do
    {:ok, port} = :inet.port(socket)
    {:reply, port, socket}
  end

  defp loop(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        case :inet.peername(client) do
          {:ok, {ip, port}} ->
            Logger.info("[acceptor] inbound from=#{inspect({ip, port})}")

          _ ->
            Logger.info("[acceptor] inbound client")
        end

        Handshakes.recv(client)

      {:error, reason} ->
        Logger.warning("acceptor accept failed reason=#{inspect(reason)}")
        Process.sleep(100)
    end

    loop(socket)
  end

  defp open_listen_socket(default) do
    Enum.find_value(
      Acceptor.port_range(),
      default,
      fn number ->
        case :gen_tcp.listen(number, Acceptor.tcp_socket_options(:inet6)) do
          {:ok, _socket} = ok ->
            ok

          {:error, _} ->
            case :gen_tcp.listen(number, Acceptor.tcp_socket_options(:inet)) do
              {:ok, _socket} = ok -> ok
              {:error, _} -> nil
            end
        end
      end
    )
  end
end

defmodule Acceptor.Connection.Handler do
  use GenServer, start: {GenServer, :start_link, [__MODULE__, nil, [name: __MODULE__]]}

  alias Acceptor.Connection.Handshakes
  require Logger

  @moduledoc """
  ListenSocket controls a :gen_tcp.listen
  and do not need to be closed manually
  """

  @spec port() :: :inet.port_number()
  def port, do: GenServer.call(__MODULE__, :port)

  def init(_) do
    with {:ok, socket} <- open_listen_socket({:stop, :no_free_port}) do
      {:ok, port} = :inet.port(socket)
      %{inet: ip4, inet6_all: v6_all} = Acceptor.all_global_ips()

      Logger.info(
        "[acceptor] listening proto=tcp port=#{port} ipv4=#{if ip4, do: Acceptor.format_ip(ip4), else: "none"} ipv6_all=#{Enum.map_join(v6_all, ",", &Acceptor.format_ip/1)} dual_stack=#{v6_all != []}"
      )

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
            Logger.debug("[acceptor] inbound from=#{inspect({ip, port})}")

          _ ->
            Logger.debug("[acceptor] inbound client")
        end

        Handshakes.recv(client)

      {:error, reason} ->
        Logger.warning("acceptor accept failed reason=#{inspect(reason)}")
        Process.sleep(100)
    end

    loop(socket)
  end

  defp open_listen_socket(default) do
    Enum.find_value(Acceptor.port_range(), default, &listen_on_port/1)
  end

  defp listen_on_port(number) do
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
end

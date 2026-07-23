defmodule UTP.Dispatcher do
  @moduledoc """
  uTP UDP demultiplexer — shares the DHT UDP socket (BEP 29 / common client practice).

  Incoming uTP packets are routed by `{peer_ip, peer_port, conn_id}` to a `UTP.Connection`.
  """
  use GenServer
  require Logger

  @table :utp_connections
  @st_syn 4

  @accept_callback Acceptor.Connection.Handshakes

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(0..65535, :inet.ip_address(), :inet.port_number(), pid()) :: :ok
  def register(conn_id, ip, port, pid) do
    true = :ets.insert(@table, {conn_key(ip, port, conn_id), pid})
    :ok
  end

  @doc false
  @spec register_pair(0..65535, 0..65535, :inet.ip_address(), :inet.port_number(), pid()) ::
          :ok
  def register_pair(recv_id, send_id, ip, port, pid) do
    :ok = register(recv_id, ip, port, pid)
    :ok = register(send_id, ip, port, pid)
  end

  @spec unregister(0..65535, :inet.ip_address(), :inet.port_number()) :: :ok
  def unregister(conn_id, ip, port) do
    # OTP app stop races are expected: UTP.Dispatcher (and its named ETS table) can
    # disappear between an existence check and :ets.delete/2 when lingering
    # UTP.Connection processes shut down on :close.
    try do
      if :ets.info(@table) != :undefined do
        :ets.delete(@table, conn_key(ip, port, conn_id))
      end
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc false
  @spec unregister_pair(0..65535, 0..65535, :inet.ip_address(), :inet.port_number()) :: :ok
  def unregister_pair(recv_id, send_id, ip, port) do
    :ok = unregister(recv_id, ip, port)
    :ok = unregister(send_id, ip, port)
  end

  @spec dispatch(port(), :inet.ip_address(), :inet.port_number(), binary()) :: :ok
  def dispatch(udp_socket, ip, port, packet) do
    GenServer.cast(__MODULE__, {:dispatch, udp_socket, ip, port, packet})
    :ok
  end

  @spec send_udp(port(), :inet.ip_address(), :inet.port_number(), iodata()) :: :ok
  def send_udp(udp_socket, ip, port, data) do
    case DHT.send_udp(ip, port, data) do
      :ok -> :ok
      {:error, :disabled} when is_port(udp_socket) -> :gen_udp.send(udp_socket, ip, port, data)
      other -> other
    end
  end

  @default_connect_timeout 5_000
  @connect_call_slack 1_500

  @spec connect(:inet.ip_address(), :inet.port_number(), keyword(), timeout()) ::
          {:ok, UTP.Connection.socket_ref()} | {:error, term()}
  def connect(ip, port, opts \\ [], timeout \\ @default_connect_timeout) do
    opts = Keyword.put_new(opts, :timeout, timeout)

    case start_connect(ip, port, opts) do
      {:ok, socket_ref} ->
        try do
          case await_client(socket_ref, timeout) do
            :ok ->
              {:ok, socket_ref}

            {:error, _} = error ->
              _ = UTP.Connection.close(socket_ref)
              error
          end
        catch
          :exit, _ ->
            _ = UTP.Connection.close(socket_ref)
            {:error, :timeout}
        end

      {:error, _} = error ->
        error
    end
  end

  @spec start_connect(:inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, UTP.Connection.socket_ref()} | {:error, term()}
  defp start_connect(ip, port, opts) do
    call_timeout = Keyword.get(opts, :timeout, @default_connect_timeout) + @connect_call_slack

    try do
      case GenServer.call(__MODULE__, {:start_connect, ip, port, opts}, call_timeout) do
        {:ok, socket_ref} -> {:ok, socket_ref}
        {:error, _} = error -> error
      end
    catch
      :exit, _ -> {:error, :timeout}
    end
  end

  defp await_client(socket_ref, timeout) do
    case UTP.Connection.await_connected(socket_ref, timeout) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  @spec notify_accept(UTP.Connection.socket_ref(), :inet.ip_address(), :inet.port_number()) ::
          :ok
  def notify_accept(socket_ref, ip, port) do
    GenServer.cast(__MODULE__, {:accept, socket_ref, ip, port})
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_connect, ip, port, opts}, _from, _state) do
    reply =
      with {:ok, udp_socket} <- udp_socket(ip),
           {:ok, socket_ref} <- UTP.Connection.start_client(udp_socket, ip, port, opts) do
        {:ok, socket_ref}
      end

    {:reply, reply, %{}}
  end

  @impl true
  def handle_cast({:dispatch, udp_socket, ip, port, packet}, state) do
    route_packet(udp_socket, ip, port, packet)
    {:noreply, state}
  end

  def handle_cast({:accept, socket_ref, ip, port}, state) do
    Logger.info("[utp] inbound accept peer=#{inspect({ip, port})}")

    _ =
      Task.Supervisor.start_child(Acceptor.Connection.Handshakes, fn ->
        @accept_callback.recv_utp(socket_ref)
      end)

    {:noreply, state}
  end

  defp route_packet(udp_socket, ip, port, packet) do
    case UTP.Packet.decode(packet) do
      {:ok, header, payload, extensions} ->
        key = conn_key(ip, port, header.conn_id)

        case :ets.lookup(@table, key) do
          [{^key, pid}] when is_pid(pid) ->
            send(pid, {:utp_packet, header, payload, extensions})

          [] when header.type == @st_syn ->
            handle_syn(ip, port, udp_socket, header, payload, extensions)

          [] ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp handle_syn(ip, port, udp_socket, header, payload, extensions) do
    case UTP.Connection.start_server(udp_socket, ip, port, header.conn_id) do
      {:ok, {:utp, pid}} ->
        recv_id = rem(header.conn_id + 1, 65536)
        send_id = header.conn_id
        :ok = register_pair(recv_id, send_id, ip, port, pid)
        send(pid, {:utp_packet, header, payload, extensions})

      {:error, reason} ->
        Logger.warning(
          "[utp] inbound syn failed peer=#{inspect({ip, port})} reason=#{inspect(reason)}"
        )
    end
  end

  defp conn_key(ip, port, conn_id), do: {ip, port, conn_id}

  defp udp_socket(ip) do
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    case DHT.udp_socket(family) do
      nil -> {:error, :no_udp_socket}
      socket -> {:ok, socket}
    end
  end
end

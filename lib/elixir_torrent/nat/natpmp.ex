defmodule NAT.NATPMP do
  @moduledoc false

  @version 0
  @port 5351
  @recv_timeout 2_000

  @op_map_udp 1
  @op_map_tcp 2

  @spec encode_map_request(:tcp | :udp, :inet.port_number(), :inet.port_number(), pos_integer()) ::
          binary()
  def encode_map_request(proto, internal_port, external_port, lifetime_seconds)
      when proto in [:tcp, :udp] and is_integer(internal_port) and internal_port > 0 and
             is_integer(external_port) and external_port > 0 and lifetime_seconds > 0 do
    opcode = if proto == :udp, do: @op_map_udp, else: @op_map_tcp

    <<
      @version,
      opcode,
      0::16,
      internal_port::16,
      external_port::16,
      lifetime_seconds::32
    >>
  end

  @spec decode_map_response(binary()) ::
          {:ok, :inet.port_number(), :inet.port_number(), pos_integer()}
          | {:error, term()}
  def decode_map_response(
        <<@version, _opcode, 0::16, internal_port::16, external_port::16, lifetime::32, _::binary>>
      ) do
    {:ok, internal_port, external_port, lifetime}
  end

  def decode_map_response(<<@version, _opcode, result_code::16, _::binary>>) when result_code != 0 do
    {:error, {:natpmp, result_code}}
  end

  def decode_map_response(_), do: {:error, :invalid_response}

  @spec map_port(:inet.ip_address(), :tcp | :udp, :inet.port_number(), pos_integer()) ::
          {:ok, :inet.port_number(), pos_integer()} | {:error, term()}
  def map_port(gateway, proto, port, lifetime_seconds \\ 7200)
      when proto in [:tcp, :udp] and is_integer(port) and port > 0 do
    bind_ip = Acceptor.primary_ips().inet || {0, 0, 0, 0}
    packet = encode_map_request(proto, port, port, lifetime_seconds)

    with {:ok, socket} <- open_socket(bind_ip),
         :ok <- :gen_udp.send(socket, gateway, @port, packet),
         {:ok, data} <- recv_udp(socket, @recv_timeout),
         :ok <- safe_close(socket),
         {:ok, _internal, external, lifetime} <- decode_map_response(data) do
      {:ok, external, lifetime}
    else
      {:error, _} = error ->
        error

      :error ->
        {:error, :timeout}
    end
  catch
    :exit, _ -> {:error, :timeout}
  end

  defp open_socket(bind_ip) do
    opts = [:binary, active: false, reuseaddr: true, ip: bind_ip]
    :gen_udp.open(0, opts)
  end

  @spec default_gateway() :: :inet.ip_address() | nil
  def default_gateway do
    case Acceptor.primary_ips().inet do
      {a, b, c, _d} when a > 0 -> {a, b, c, 1}
      _ -> nil
    end
  end

  defp recv_udp(socket, timeout) do
    case :gen_udp.recv(socket, 0, timeout) do
      {:ok, data} -> {:ok, data}
      error -> error
    end
  end

  defp safe_close(socket) do
    :gen_udp.close(socket)
    :ok
  catch
    _, _ -> :ok
  end
end

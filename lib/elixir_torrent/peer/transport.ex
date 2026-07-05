defmodule Peer.Transport do
  @moduledoc """
  Thin transport abstraction over TCP (`:gen_tcp`) and uTP (`UTP.Socket`).
  """

  @type socket :: :gen_tcp.socket() | UTP.Connection.socket_ref()

  @spec connect(:inet.ip_address(), :inet.port_number(), keyword(), timeout()) ::
          {:ok, socket()} | {:error, term()}
  def connect(ip, port, opts, timeout) do
    transport = Keyword.get(opts, :transport, :tcp)

    case transport do
      :utp -> UTP.Socket.connect(ip, port, opts, timeout)
      :tcp -> :gen_tcp.connect(ip, port, opts, timeout)
      other -> {:error, {:unsupported_transport, other}}
    end
  end

  @spec send(socket(), iodata()) :: :ok | {:error, term()}
  def send({:utp, _} = socket, data), do: UTP.Socket.send(socket, data)
  def send(socket, data) when is_port(socket), do: :gen_tcp.send(socket, data)

  @spec recv(term(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv({:utp, _} = socket, len, timeout), do: UTP.Socket.recv(socket, len, timeout)
  def recv(socket, len, timeout) when is_port(socket), do: :gen_tcp.recv(socket, len, timeout)

  @spec close(socket()) :: :ok
  def close({:utp, _} = socket), do: UTP.Socket.close(socket)

  def close(socket) when is_port(socket) do
    _ = :gen_tcp.shutdown(socket, :write)
    :gen_tcp.close(socket)
    :ok
  end

  @spec controlling_process(socket(), pid()) :: :ok | {:error, term()}
  def controlling_process({:utp, _} = socket, pid), do: UTP.Socket.controlling_process(socket, pid)

  def controlling_process(socket, pid) when is_port(socket),
    do: :gen_tcp.controlling_process(socket, pid)

  @spec setopts(socket(), keyword()) :: :ok | {:error, term()}
  def setopts({:utp, _} = socket, opts), do: UTP.Socket.setopts(socket, opts)
  def setopts(socket, opts) when is_port(socket), do: :inet.setopts(socket, opts)

  @spec peername(socket()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def peername({:utp, _} = socket), do: UTP.Socket.peername(socket)
  def peername(socket) when is_port(socket), do: :inet.peername(socket)

  @spec utp?(socket() | term()) :: boolean()
  def utp?(socket), do: UTP.Socket.utp?(socket)
end

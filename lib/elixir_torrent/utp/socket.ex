defmodule UTP.Socket do
  @moduledoc """
  gen_tcp-compatible subset for uTP connections used by the BitTorrent peer wire protocol.
  """

  @type t :: UTP.Connection.socket_ref()

  @spec connect(:inet.ip_address(), :inet.port_number(), keyword(), timeout()) ::
          {:ok, t()} | {:error, term()}
  def connect(ip, port, opts \\ [], timeout \\ 15_000) do
    UTP.Dispatcher.connect(ip, port, opts, timeout)
  end

  @spec send(t(), iodata()) :: :ok | {:error, term()}
  def send(socket, data), do: UTP.Connection.send_raw(socket, data)

  @spec recv(t(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv(socket, len, timeout), do: UTP.Connection.recv_raw(socket, len, timeout)

  @spec close(t()) :: :ok
  def close(socket), do: UTP.Connection.close(socket)

  @spec controlling_process(t(), pid()) :: :ok | {:error, term()}
  def controlling_process(socket, pid), do: UTP.Connection.controlling_process(socket, pid)

  @spec setopts(t(), keyword()) :: :ok | {:error, term()}
  def setopts({:utp, pid}, active: true) do
    UTP.Connection.activate({:utp, pid})
  end

  def setopts({:utp, pid}, active: false) do
    UTP.Connection.deactivate({:utp, pid})
  end

  def setopts({:utp, _}, opts) do
    {:error, {:unsupported_opts, opts}}
  end

  @spec peername(t()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def peername(socket), do: UTP.Connection.peername(socket)

  @spec utp?(term()) :: boolean()
  def utp?({:utp, _}), do: true
  def utp?(_), do: false
end

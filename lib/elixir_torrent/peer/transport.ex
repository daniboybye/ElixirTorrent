defmodule Peer.Transport do
  @moduledoc """
  Thin transport abstraction over TCP (`:gen_tcp`) and uTP (`UTP.Socket`).

  An `{:mse, inner, %{recv, send}}` socket layers MSE/PE RC4 encryption over any
  inner transport: every `send/2` is encrypted with the outbound cipher and
  every `recv/3` decrypted with the inbound one. The ciphers are stateful RC4
  streams, so a single owner must drive the socket in order (which the peer
  process does). Active-mode data still arrives tagged with the *inner* socket;
  `raw/1` exposes it so the receiver can match and decrypt those messages.
  """

  # Our send/2 wraps the inner transport recursively; shadow Kernel.send cleanly.
  import Kernel, except: [send: 2]

  alias Peer.MSE

  @type mse_ciphers :: %{recv: MSE.cipher(), send: MSE.cipher()}
  @type base_socket :: :gen_tcp.socket() | UTP.Connection.socket_ref()
  @type socket :: base_socket() | {:mse, base_socket(), mse_ciphers()}

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

  @doc "Wrap an inner socket with MSE RC4 ciphers negotiated by the handshake."
  @spec wrap(base_socket(), mse_ciphers()) :: socket()
  def wrap(inner, %{recv: _, send: _} = ciphers), do: {:mse, inner, ciphers}

  @doc "The underlying transport socket (the inner one for MSE, else the socket)."
  @spec raw(socket()) :: term()
  def raw({:mse, inner, _}), do: inner
  def raw(socket), do: socket

  @doc "Whether the socket carries an MSE encryption layer."
  @spec mse?(term()) :: boolean()
  def mse?({:mse, _, _}), do: true
  def mse?(_), do: false

  @spec send(socket(), iodata()) :: :ok | {:error, term()}
  def send({:mse, inner, ciphers}, data), do: send(inner, MSE.crypt(ciphers.send, data))
  def send({:utp, _} = socket, data), do: UTP.Socket.send(socket, data)
  def send(socket, data) when is_port(socket), do: :gen_tcp.send(socket, data)

  @spec recv(term(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv({:mse, inner, ciphers}, len, timeout) do
    with {:ok, enc} <- recv(inner, len, timeout) do
      {:ok, MSE.crypt(ciphers.recv, enc)}
    end
  end

  def recv({:utp, _} = socket, len, timeout), do: UTP.Socket.recv(socket, len, timeout)
  def recv(socket, len, timeout) when is_port(socket), do: :gen_tcp.recv(socket, len, timeout)

  @doc """
  Like `recv/3`, but never raises when the transport owner exits during the read
  (uTP shutdown, peer disconnect). Maps clean exits to `{:error, :closed}`.
  """
  @spec safe_recv(term(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def safe_recv(socket, len, timeout) do
    recv(socket, len, timeout)
  catch
    :exit, reason -> {:error, peer_exit_reason(reason)}
  end

  @doc """
  Like `send/2`, but never raises when the transport owner exits mid-send
  (uTP connection torn down, peer disconnect under churn/CGNAT).
  """
  @spec safe_send(socket(), iodata()) :: :ok | {:error, term()}
  def safe_send(socket, data) do
    send(socket, data)
  catch
    :exit, reason -> {:error, peer_exit_reason(reason)}
  end

  @doc """
  Like `peername/1`, but never raises when the uTP connection GenServer is gone.
  """
  @spec safe_peername(socket()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def safe_peername(socket) do
    peername(socket)
  catch
    :exit, reason -> {:error, peer_exit_reason(reason)}
  end

  @doc false
  @spec peer_exit_reason(term()) :: term()
  def peer_exit_reason(:normal), do: :closed
  def peer_exit_reason({:normal, _}), do: :closed
  def peer_exit_reason({:shutdown, _}), do: :closed
  def peer_exit_reason({:noproc, _}), do: :closed
  def peer_exit_reason(other), do: other

  @spec decrypt_inbound(socket(), binary()) :: binary()
  def decrypt_inbound({:mse, _inner, ciphers}, data), do: MSE.crypt(ciphers.recv, data)
  def decrypt_inbound(_socket, data), do: data

  @spec close(socket()) :: :ok
  def close({:mse, inner, _}), do: close(inner)
  def close({:utp, _} = socket), do: UTP.Socket.close(socket)

  def close(socket) when is_port(socket) do
    _ = :gen_tcp.shutdown(socket, :write)
    :gen_tcp.close(socket)
    :ok
  end

  @spec controlling_process(socket(), pid()) :: :ok | {:error, term()}
  def controlling_process({:mse, inner, _}, pid), do: controlling_process(inner, pid)

  def controlling_process({:utp, _} = socket, pid),
    do: UTP.Socket.controlling_process(socket, pid)

  def controlling_process(socket, pid) when is_port(socket),
    do: :gen_tcp.controlling_process(socket, pid)

  @spec setopts(socket(), keyword()) :: :ok | {:error, term()}
  def setopts({:mse, inner, _}, opts), do: setopts(inner, opts)
  def setopts({:utp, _} = socket, opts), do: UTP.Socket.setopts(socket, opts)
  def setopts(socket, opts) when is_port(socket), do: :inet.setopts(socket, opts)

  @spec peername(socket()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def peername({:mse, inner, _}), do: peername(inner)
  def peername({:utp, _} = socket), do: UTP.Socket.peername(socket)
  def peername(socket) when is_port(socket), do: :inet.peername(socket)

  @spec utp?(socket() | term()) :: boolean()
  def utp?({:mse, inner, _}), do: UTP.Socket.utp?(inner)
  def utp?(socket), do: UTP.Socket.utp?(socket)
end

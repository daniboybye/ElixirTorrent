defmodule Peer.Receiver do
  use GenServer

  require Peer.Const
  require Logger

  alias Peer.Controller

  Peer.Const.message_id()
  @max_length trunc(:math.pow(2, 14))

  @doc """
  Receiver controls a :gen_tcp.socket 
  and do not need to be closed manually
  """

  @spec start_link({Peer.key(), Acceptor.socket()}) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init({_, socket} = args) do
    :ok = Acceptor.Pool.remove_control(socket)
    send(self(), :loop)
    {:ok, args}
  end

  def terminate(:protocol_error, peer_id), do: Acceptor.BlackList.put(peer_id)

  def terminate(_, _), do: :ok

  def handle_info(:loop, {{peer_id, _} = key, socket}) do
    {:stop, loop(socket, key), peer_id}
  end

  defp get_message(_, 0), do: {:ok, <<>>}

  defp get_message(socket, len), do: :gen_tcp.recv(socket, len, @timeout_recv)

  defp loop(socket, key) do
    with {:ok, <<len::32>>} <- :gen_tcp.recv(socket, 4, @timeout_recv),
         {:ok, message} <- get_message(socket, len),
         :ok <- handle(message, key) do
      loop(socket, key)
    end
  end

  defp handle(<<>>, _), do: :ok

  defp handle(<<@choke_id>>, key), do: Controller.handle_choke(key)

  defp handle(<<@unchoke_id>>, key), do: Controller.handle_unchoke(key)

  defp handle(<<@interested_id>>, key), do: Controller.handle_interested(key)

  defp handle(<<@not_interested_id>>, key) do
    Controller.handle_not_interested(key)
  end

  defp handle(<<@have_id, index::32>>, key) do
    Controller.handle_have(key, index)
  end

  defp handle(<<@bitfield_id, bitfield::binary>>, key) do
    Controller.handle_bitfield(key, bitfield)
  end

  defp handle(<<@request_id, index::32, begin::32, length::32>>, key)
       when length <= @max_length do
    Controller.handle_request(key, index, begin, length)
  end

  defp handle(<<@piece_id, index::32, begin::32, block::binary>>, key) do
    Controller.handle_piece(key, index, begin, block)
  end

  defp handle(<<@cancel_id, index::32, begin::32, length::32>>, key) do
    Controller.handle_cancel(key, index, begin, length)
  end

  defp handle(<<@port_id, port::16>>, key) do
    Controller.handle_port(key, port)
  end

  defp handle(_, _), do: :ok
end

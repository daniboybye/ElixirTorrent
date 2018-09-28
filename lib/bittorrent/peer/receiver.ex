defmodule Peer.Receiver do
  use GenServer

  require Peer.Const
  require Logger

  alias Peer.Controller
  alias Acceptor.{Pool, BlackList}

  Peer.Const.message_id()
  @max_length trunc(:math.pow(2, 14))

  @doc """
  Receiver controls a :gen_tcp.socket 
  and do not need to be closed manually
  """

  @spec start_link({Peer.id, Torrent.hash(), port()}) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init({_id, _hash, socket} = args) do
    :ok = Pool.remove_control(socket)
    {:ok, nil, {:continue, args}}
  end

  def terminate({:shutdown, :protocol_error}, id), do: BlackList.put(id)

  def terminate(_, _), do: :ok

  def handle_continue({id, hash, socket}, nil) do
    {:stop, {:shutdown, loop(socket, Peer.make_key(hash, id))}, id}
  end

  defp get_message(_, 0), do: {:ok, <<>>}

  defp get_message(socket, len) do
    :gen_tcp.recv(socket, len, 70_000)
  end

  defp loop(socket, key) do
    with {:ok, <<len::32>>} <- :gen_tcp.recv(socket, 4, 130_000),
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

  defp handle(<<@have_all_id>>, key), do: Controller.handle_have_all(key)

  defp handle(<<@have_none_id>>, key), do: Controller.handle_have_none(key)

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

  defp handle(<<@suggest_piece_id, index::32>>, key) do
    Controller.handle_suggest_piece(key, index)
  end

  defp handle(<<@reject_request_id, index::32, begin::32, length::32>>, key) do
    Controller.handle_reject(key, index, begin, length)
  end

  defp handle(<<@allowed_fast_id, index::32>>, key) do
    Controller.handle_allowed_fast(key, index)
  end

  defp handle(_, _), do: :ok
end

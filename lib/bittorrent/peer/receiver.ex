defmodule Bittorrent.Peer.Receiver do
  use GenServer

  import Bittorrent
  import Bittorrent.Torrent
  require Via

  Via.make()

  @timeout 120_000

  @doc """
  key = {peer_id, info_hash} 
  """

  def start_link({key,_} = args) do
    GenServer.start_link(__MODULE__,args, name: via(key))
  end

  def init({_,socket} = state) do
    case :gen_tcp.controlling_process(socket, self()) do
      :ok ->
        send(self(), :loop)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def terminate(:protocol_error,{{peer_id,_}, socket}) do
    BlackList.put(peer_id)
    :gen_tcp.close(socket)
  end

  def terminate(_, {_,socket}) do
    :gen_tcp.close(socket)
  end

  def handle_info(:loop, {server,socket} = state) do
    {:stop, loop(<<>>,server,socket) , state}
  end

  defp loop(<<>>, server, socket) do
    case :gen_tcp.recv(socket, 0, @timeout) do
      {:ok, message} ->
        loop(message,server,socket)
      _ ->
        :timeout
    end
  end

  defp loop(<<len::32,message::bytes-size(len),tail::binary>>,server,socket) do
    case handle(message,server) do
      :ok -> loop(tail,server,socket)
      reason -> reason
    end
  end

  defp loop(_,server,_), do: :protocol_error

  defp handle(<<>>,_), do: :ok

  defp handle(<<0>>,server), do: Server.choke(server)

  defp handle(<<1>>,server), do: Server.unchoke(server)

  defp handle(<<2>>,server), do: Server.interested(server)

  defp handle(<<3>>,server), do: Server.not_interested(server)

  defp handle(<<4,piece_index::32>>,server) do
    Server.have(server,piece_index)
  end

  defp handle(<<5,bitfield::binary>>,server) do
    Server.bitfield(server,bitfield)
  end

  defp handle(<<6,index::32,begin::32,length::32>>,server) do
    Server.request(server,index,begin,legnth)
  end

  defp handle(<<7,index::32,begin::32,block::32>>,server) do
    Server.piece(server,index,begin,block)
  end

  defp handle(<<8,index::32,begin::32,length::32>>,server) do
    Server.cancel(server,index,begin,legnth)
  end

  defp handle(<<9,port::16>>,server), do: Server.port(server,port)

  defp handle(_,server), do: :protocol_error
end

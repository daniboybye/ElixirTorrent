defmodule Bittorrent.Peer.Receiver do
  use GenController

  import Bittorrent.Torrent

  @timeout 120_000
  @max_length :math.pow(2,14)

  @doc """
  key = {peer_id, hash} 

  Reveiver controls a :gen_tcp.socket 
  and do not need to be closed manually
  """

  def start_link(args), do: GenController.start_link(__MODULE__,args)

  def init({_,socket} = state) do
    case :gen_tcp.controlling_process(socket, self()) do
      :ok ->
        send(self(), :loop)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def terminate(:protocol_error, peer_id), do: BlackList.put(peer_id)

  def terminate(_, _), do: :ok

  def handle_info(:loop, {{peer_id,_} = cont,socket} = state) do
    {:stop, loop(<<>>,cont,socket) , peer_id}
  end

  defp loop(<<>>, key, socket) do
    case :gen_tcp.recv(socket, 0, @timeout) do
      {:ok, message} ->
        loop(message,key,socket)
      _ ->
        :timeout
    end
  end

  defp loop(<<len::32,message::bytes-size(len),tail::binary>>,cont,socket) do
    case handle(message,cont) do
      :ok -> loop(tail,cont,socket)
      reason -> reason
    end
  end

  defp loop(_,_,_), do: :protocol_error

  defp handle(<<>>,_), do: :ok

  defp handle(<<0>>,key), do: Controller.choke(key)

  defp handle(<<1>>,key), do: Controller.unchoke(key)

  defp handle(<<2>>,key), do: Controller.interested(key)

  defp handle(<<3>>,key), do: Controller.not_interested(key)

  defp handle(<<4,piece_index::32>>,key) do
    Controller.have(key,piece_index)
  end

  defp handle(<<5,bitfield::binary>>,key) do
    Controller.bitfield(key,bitfield)
  end

  defp handle(<<6,index::32,begin::32,length::32>>,{_,hash}=key) when length <= @max_length do
    Controller.handle_request(key,index,begin,length)
      
    end

    :ok
  end

  defp handle(<<7,index::32,begin::32,block::32>>,{peer_id,hash}) do
    Server.piece(hash,peer_id,index,begin,block)
  end

  defp handle(<<8,index::32,begin::32,length::32>>,key) do
    Controller.cancel(key,index,begin,legnth)
  end

  defp handle(<<9,port::16>>,c), do: Controller.port(c,port)

  defp handle(_,_), do: :protocol_error
end

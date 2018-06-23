defmodule Bittorrent.Peer.Receiver do
  use GenServer

  import Bittorrent.Torrent

  def start_link(args) do
    GenServer.start_link(__MODULE__,args)
  end

  def loop(receiver) do
    GenServer.cast(receiver,{:loop,self()})
  end

  def init(socket) do
    case :gen_tcp.controlling_process(socket, self()) do
      :ok ->
        {:ok, socket}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def terminate(_, socket) do
    :gen_tcp.close(socket)
  end

  def handle_cast({:loop, server}, socket) do
    loop(<<>>,server,socket)
  end

  defp loop(<<>>, server, socket) do
    case :gen_tcp.recv(socket, 0, 120_000) do
      {:ok, message} ->
        loop(message,server,socket)
      _ ->
        {:stop,:timeout,socket}
    end
  end

  defp loop(<<len::32,message::bytes-size(len),tail::binary>>,server,socket) do
    handle(message,server)
    loop(tail,server,socket)
  end

  defp loop(_,server,socket) do
    Server.protocol_error(server)
    {:noreply,socket}
  end

  defp handle(<<>>,server) do
    :ok
  end

  defp handle(<<0>>,server) do
    Server.choke(server)
  end

  defp handle(<<1>>,server) do
    Server.unchoke(server)
  end

  defp handle(<<2>>,server) do
    Server.interested(server)
  end

  defp handle(<<3>>,server) do
    Server.not_interested(server)
  end

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

  defp handle(<<9,port::16>>,server) do
    Server.port(server,port)
  end

  defp handle(_,server) do
    Server.protocol_error(server)
  end
end

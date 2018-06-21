defmodule Bittorrent.Peer.Transmitter do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__,args)    
  end

  def init(socket) do
    {:ok,{socket, :queue.new()}}
  end

  :queue.in()
  :queue.in_r()
end

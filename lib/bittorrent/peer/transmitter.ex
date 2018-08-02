defmodule Bittorrent.Peer.Transmitter do
  use GenServer

  import Bittorrent
  import Bittorrent.Peer
  require Via

  Via.make()

  @keeplive <<0,0,0,0>>

  @doc """
  key = {peer_id, hash} 
  """

  def start_link(key) do
    GenServer.start_link(__MODULE__,key,name: via(key))    
  end

  def send(key), do: GenServer.cast(via(key), :send)

  def send_message(key, message), do: Sender.send(key, message)

  def choke_me(key), do: GenServer.cast(via(key),:choke_me)

  def push_back(key,message) do
    GenServer.cast(via(key),{:push_back, message})
  end

  def push_front(key,message) do
    GenServer.cast(via(key),{:push_front, message})
  end

  def init(key), do: {:ok,{key, :queue.new()}}

  def handle_cast(:choke_me,{key,_}) do
    {:noreply,{key,:queue.new()}}
  end

  def handle_cast(:send,{key,{[],[]}}=state) do
    do_send(key,@keeplive,state)
  end

  def handle_cast(:send,{key,queue}) do
    {{:value, message}, queue} = :queue.out(queue)
    do_send(key,message,{key,queue})
  end

  def handle_cast({:push_back,message},{key,queue}) do
    {:noreply, {key,:queue.in(message,queue)}}
  end

  def handle_cast({:push_front,message},{key,queue}) do
    {:noreply, {key,:queue.in_r(message,queue)}}
  end

  defp do_send(key,message,state) do
    Sender.send(key,message)
    {:noreply,state}
  end
end

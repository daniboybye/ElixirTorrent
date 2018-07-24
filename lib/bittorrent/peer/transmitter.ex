defmodule Bittorrent.Peer.Transmitter do
  use GenServer

  import Bittorrent
  import Bittorrent.Peer
  require Via

  Via.make()

  @doc """
  key = {peer_id, info_hash} 
  """

  def start_link(key) do
    GenServer.start_link( __MODULE__,key,name: via(key))    
  end

  def send(key), do: GenServer.cast(via(key), :send)

  def push_front_send(key, message), do: Sender.send(key, message)

  def member?(key,message) do
    GenServer.call(via(key), {:member?, message})
  end

  def empty?(key), do: GenServer.call(via(key),:empty?)

  def push_back(key,message) do
    GenServer.cast(via(key),{:push_back, message})
  end

  def push_front(key,message) do
    GenServer.cast(via(key),{:push_front, message})
  end

  def pop(key), do: GenServer.call(via(key), :pop)

  def init(key) do
    {:ok,{key, :queue.new()}}
  end

  def handle_call({:member?,message},{_,queue} = state) do
    {:reply, :queue.member?(message,queue),state}
  end

  def handle_call({:empty?,message},{_,queue} = state) do
    {:reply, :queue.empty?(queue),state}
  end

  def handle_call(:pop, {key,queue} = state) do
    case :queue.out(queue) do
      {{:value, message},queue} -> {:reply, message, {key, queue}}
      {:empty,_} -> {:reply,nil,state}
    end
  end

  def handle_cast(:send,{key,queue}) do
    {{:value, message}, queue} = :queue.out(queue)
    Sender.send(key, message)
    {:noreply, {key, queue}}
  end

  def handle_cast({:send,message},{key,_} = state) do
    Sender.send(key, message)
    {:noreply, state}
  end

  def handle_cast({:push_back,message},{key,queue}) do
    {:noreply, {key,:queue.in(message,queue)}}
  end

  def handle_cast({:push_front,message},{key,queue}) do
    {:noreply, {key,:queue.in_r(message,queue)}}
  end
end

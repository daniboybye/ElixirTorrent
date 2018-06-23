defmodule Bittorrent.Peer.Transmitter do
  use GenServer

  @timeout 100_000
  @keeplive <<0,0,0,0>>

  def start_link(args) do
    GenServer.start_link(__MODULE__,args)    
  end

  def send(transmitter) do
    GenServer.cast(transmitter,:send)
  end

  def push_front_send(message,transmitter) do
    GenServer.cast(transmitter,{:send,message})
  end

  def member?(transmitter,message) do
    GenServer.call(transmitter,{:member?, message})
  end

  def empty?(transmitter) do
    GenServer.call(transmitter,:empty?)
  end

  def push_back(transmitter,message) do
    GenServer.cast(transmitter,{:push_back, message})
  end

  def push_front(transmitter,message) do
    GenServer.cast(transmitter,{:push_front, message})
  end

  def init(socket) do
    {:ok,{socket, :queue.new()},@timeout}
  end

  def handle_call({:member?,message},{_,queue} = state) do
    {:reply, :queue.member?(message,queue),state, @timeout}
  end

  def handle_call({:empty?,message},{_,queue} = state) do
    {:reply, :queue.empty?(queue),state, @timeout}
  end

  def handle_cast(:send,{socket,queue} = state) do
    {{:value, message},new_queue} = :queue.out(queue)
    :gen_tcp.send(socket,message)
    {:noreply,{socket,new_queue},@timeout}
  end

  def handle_cast({:send,message},{socket,_} = state) do
    :gen_tcp.send(socket,message)
    {:noreply,state,@timeout}
  end

  def handle_cast({:push_back,message},{socket,queue}) do
    {:noreply, {socket,:queue.in(message,queue)},@timeout}
  end

  def handle_cast({:push_front,message},{socket,queue}) do
    {:noreply, {socket,:queue.in_r(message,queue)},@timeout}
  end

  def handle_info(:timeout,{socket,{[],[]}} = state) do
    :gen_tcp.send(socket,@keeplive)
    {:noreply,state,@timeout}
  end

  def handle_info(:timeout,state) do
    __MODULE__.send(self())
    {:noreply,state}
  end
end

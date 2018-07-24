defmodule Bittorrent.Peer.Sender do
  use GenServer

  import Bittorrent
  import Bittorent.Peer
  require Via

  Via.make()

  @timeout 115_000
  @keeplive <<0,0,0,0>>
  
  @doc """
  key = {peer_id, info_hash} 
  """

  def start_link({key, _} = args) do
    GenServer.start_link(__MODULE__, args, name: via(key))    
  end

  def send(key, message), do: GenServer.cast(via(key),{:send, message})

  def init(state), do: {:ok, state, @timeout}

  def handle_cast({:send, message}, {_, socket} = state) do
    :gen_tcp.send(socket,message)
    {:noreply,state,@timeout}
  end

  def handle_info(:timeout,{key, socket} = state) do
    case Transmitter.pop(key) do
      nil ->     @keeplive
      message -> message
    end 
    |> (&:gen_tcp.send(socket,&1)).()

    {:noreply,state, @timeout}
  end
end
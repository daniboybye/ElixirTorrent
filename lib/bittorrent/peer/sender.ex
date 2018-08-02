defmodule Bittorrent.Peer.Sender do
  use GenServer

  import Bittorrent
  import Bittorent.Peer
  require Via

  Via.make()

  @timeout 115_000
  
  @doc """
  key = {peer_id, hash} 
  """

  def start_link({key, _} = args) do
    GenServer.start_link(__MODULE__, args, name: via(key))    
  end

  def have(pid, index), do: do_send(pid, <<4,index::32>>)

  def send(key, message), do: do_send(via(key), message)

  def init(state), do: {:ok, state, @timeout}

  def handle_cast(message, {_, socket} = state) do
    :gen_tcp.send(socket,message)
    {:noreply,state,@timeout}
  end

  def handle_info(:timeout,{key, _} = state) do
    Transmitter.send(key)
    {:noreply,state}
  end

  defp do_send(sender, message), do: GenServer.cast(sender, message)
end
defmodule Bittorent.Torrent.Bitfield do
  use GenServer

  import Bittorrent
  require Via

  Via.make()

  @doc """
  key = hash 
  """

  def start_link({key,args}) do
    GenServer.start_link(__MODULE__, args, via(key))
  end

  def get(key), do: GenServer.call(via(key),:get)
  
  def add_bit(key,index), do: GenServer.cast(via(key),index)

  def check?(key,index), do: GenServer.call(via(key),index)

  def init(count) do
    count = Float.ceil(count/8) |> trunc()
    
    Stream.cycle([0])
    |> Stream.take(count)
    |> List.to_string()
    |> (&{:ok, &1}).()
  end

  def handle_call(:get,_, bitfield) do
    {:reply, bitfield, bitfield}
  end

  def handle_call(index,<<_::index,1::1,_::bits>> = state) do
    {:reply, true, state}
  end
    
  def handle_call(_,_,state), do: {:reply,false,state }

  def handle_cast(index,<<prefix::index,0::1,indextfix::bits>>) do
    {:noreply, <<prefix::bits,1::1,indextfix::bits>>}
  end

  def handle_cast(_,state), do: {:noreply, state}
  
end
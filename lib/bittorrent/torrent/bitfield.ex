defmodule Bittorent.Torrent.Bitfield do
  use GenServer

  import Bittorrent
  import Bittorrent.Torrent
  require Via

  Via.make()

  @doc """
  key = info_hash 
  """

  def start_link(key), do: GenServer.start_link(__MODULE__, key, via(key))

  def get(key), do: GenServer.call(via(key),:get)
  
  def add_bit(key,pos), do: GenServer.cast(via(key),pos)

  def init(key), do: {:ok, Bitfield.make_bitfield(key)}

  def handle_call(:get,_,{_,bitfield} = state) do
    {:reply, bitfield, state}
  end

  def handle_cast(pos,{_,<<_::pos,1::1,_::bits} = state) do
    {:noreply, state}
  end
    
  def handle_cast(pos,{size,<<prefix::pos,_::1,postfix::bits}) do
    {:noreply, {size, <<prefix::bits,1::1,postfix::bits>> }}
  end
end
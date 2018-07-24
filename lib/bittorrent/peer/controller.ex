defmodule Bittorrent.Peer.Controller do
  use GenServer

  import Bittorrent
  import Bittorrent.{Peer,Torrent,Acceptor}
  require Via

  Via.make()

  @doc """
  key = {peer_id, info_hash} 
  """

  def start_link(key) do
    GenServer.start_link(__MODULE__,key,name: via(key))
  end

  def choke(key), do: GenServer.cast(via(key), :choke)

  def unchoke(key), do: GenServer.cast(via(key), :unchoke)

  def interested(key), do: GenServer.cast(via(key),:interested)

  def not_interested(key), do: GenServer.cast(via(key), :not_interested)

  def have(key,piece_index) do
    GenServer.cast(via(key), {:have,piece_index})
  end

  def bitfield(key,bitfield) do
    GenServer.cast(via(key),{:bitfield,bitfield})
  end

  def request(key,index,begin,length) do
    GenServer.cast(via(key),{:request,index,begin,legnth})
  end

  def piece(key,index,begin,block) do
    GenServer.cast(via(key),{:piece,index,begin,block})
  end

  def cancel(key,index,begin,length) do
    GenServer.cast(via(key),{:cancel,index,begin,legnth})
  end

  def port(key,port), do: GenServer.cast(via(key),{:port,port})

  def init({_,info_hash} = key) do
    info_hash
    |> Server.bitfield()
    |> Transmitter.push_front_send(key)

    {:ok, %__MODULE__.State{
      key: key,
      pieces_size: Server.get_pieces_size(info_hash)
      }}
  end
  
  def handle_cast(:choke,) do
  
  end

  def handle_cast(:unchoke,) do
  
  end

  def handle_cast(:interested,) do
  
  end

  def handle_cast(:not_interested,) do
  
  end

  def handle_cast({:bitfield,bitfield},%__MODULE__.State{bitfield: nil} = state) do
    {:noreply, %__MODULE__.State{state | bitfield: bitfield}}
  end

  def handle_cast({:bitfield,_},state) do
    {:stop,:protocol_error,state}
  end

  def handle_cast({:request,index,begin,legnth},) do
  
  end

  def handle_cast({:piece,index,begin,block},) do
  
  end

  def handle_cast({:cancel,index,begin,legnth},) do
  
  end

  def handle_cast({:port,port},) do
  
  end
end

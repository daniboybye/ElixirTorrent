defmodule Bittorrent.Peer.Controller do
  use GenServer

  import Bittorrent.{Peer,Torrent,Acceptor}

  @timeout 120_000

  def start_link(args) do
    GenServer.start_link(__MODULE__,args)
  end

  def choke(server) do
    GenServer.cast(server,:choke)
  end

  def unchoke(server) do
    GenServer.cast(server, :unchoke)
  end

  def interested(server) do
    GenServer.cast(server,:interested)
  end

  def not_interested(server) do
    GenServer.cast(server,:not_interested)
  end

  def have(server,piece_index) do
    GenServer.cast(server,{:have,piece_index})
  end

  def bitfield(server,bitfield) do
    GenServer.cast(server,{:bitfield,bitfield})
  end

  def request(server,index,begin,length) do
    GenServer.cast(server,{:request,index,begin,legnth})
  end

  def piece(server,index,begin,block) do
    GenServer.cast(server,{:piece,index,begin,block})
  end

  def cancel(server,index,begin,length) do
    GenServer.cast(server,{:cancel,index,begin,legnth})
  end

  def port(server,port) do
    GenServer.cast(server,{:port,port})
  end

  def protocol_error(server) do
    GenServer.cast(server,:protocol_error)
  end

  def init({torrent,peer_id,parent}) do
    {receiver, transmitter} = get_receiver_transmitter(parent)
    Receiver.loop(receiver)

    torrent
    |> Server.bitfield()
    |> Transmitter.push_front_send(transmitter)

    {:ok, %__MODULE__.State{
      transmitter: transmitter,
      peer_id: peer_id,
      torrent: torrent,
      pieces_size: Server.get_pieces_size(torrent)
      }}
  end

  def terminate(:protocol_error,%__MODULE__.State{peer_id: peer_id}) do
    BlackList.put(peer_id)
  end

  def terminate(_,_), do: :ok
  
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

  def handle_cast(:protocol_error,state) do
    {:stop,:protocol_error,state}
  end

  defp get_receiver_transmitter(parent) do
    list = Supervisor.which_children(parent)
    
    {Enum.find(list,fn {x,_,_,_} -> x == Receiver end),
    Enum.find(list,fn {x,_,_,_} -> x == Transmitter end)}
  end
end

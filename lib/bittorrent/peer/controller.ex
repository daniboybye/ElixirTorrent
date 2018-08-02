defmodule Bittorrent.Peer.Controller do
  use GenServer

  import Bittorrent
  import Bittorrent.{Peer,Torrent,Acceptor}
  import __MODULE__
  require Via

  Via.make()

  @doc """
  key = {peer_id, hash} 
  """

  def start_link(key) do
    GenServer.start_link(__MODULE__,key,name: via(key))
  end

  def has_index?(pid, index) do
    GenServer.call(pid, {:has_index?, index})
  end

  def handle_choke(key), do: GenServer.cast(via(key), :choke)

  def handle_unchoke(key), do: GenServer.cast(via(key), :unchoke)

  def handle_interested(key), do: GenServer.cast(via(key),:interested)

  def handle_not_interested(key) do 
    GenServer.cast(via(key), :not_interested)
  end

  def handle_have(key,piece_index) do
    GenServer.cast(via(key), {:have,piece_index})
  end

  def handle_bitfield(key,bitfield) do
    GenServer.cast(via(key),{:bitfield,bitfield})
  end

  def handle_request(key,index,begin,length) do
    GenServer.cast(via(key),{:handle_request,index,begin,legnth})
  end

  def handle_piece(key,index,begin,block) do
    GenServer.cast(via(key),{:piece,index,begin,block})
  end

  def handle_cancel(key,index,begin,length) do
    GenServer.cast(via(key),{:cancel,index,begin,legnth})
  end

  def handle_port(key,port), do: GenServer.cast(via(key),{:port,port})
  
  def interested(pid,index) do
    GenServer.cast(pid,{:interesred,index})
  end

  def init({_,hash} = key) do
    hash
    |> Server.bitfield()
    |> Transmitter.push_front_send(key)

    {:ok, %State{
      key: key,
      pieces_count: Server.get_pieces_count(hash)
      }}
  end
  
  def terminate(:protocol_error,%State{key: {peer_id,_}}) do
    BlackList.put(peer_id)
  end

  def terminate(_,_), do: :ok

  def handle_call({:has_index?, index},_,state) do
    {:reply, do_has_index?(index, state), state}
  end

  def handle_cast(:choke,%State{choke: false,key: key} = state) do
    Sender.choke(key, true)
    {:noreply, %State{state | choke_me: true, choke: true}}
  end

  def handle_cast(:choke,state) do
    {:noreply, %State{state | choke_me: true}}
  end

  def handle_cast(:unchoke,%State{interested: true,
    choke_me: true, key: {_,hash}, piece: index} = state) do
    PieceDownload.{index,hash}
    {:noreply,%State{state | choke_me: false}}
  end

  def handle_cast(:interested,state) do
    {:noreply,%State{state | interesred_of_me: true}}
  end

  def handle_cast(:not_interested,state) do
    {:noreply,%State{state | interesred_of_me: false}}
  end

  def handle_cast({:interested, index},
    %State{key: key,choke_me: choke_me, interested: interested} = state) do
    new_interested = do_has_index?(index,state)

    if new_interested != interesred do
      Sender.send_interested(key, new_interested)
    end

    if new_interested and not choke_me do
      PieceDownload.
    end
    
    {:noreply, %State{state | interested: new_interested, piece: index}}
  end

  def handle_cast({:bitfield,bitfield},%State{bitfield: nil} = state) do
    {:noreply, %State{state | bitfield: bitfield}}
  end

  def handle_cast({:bitfield,_},state) do
    {:stop,:protocol_error,state}
  end

  def handle_cast({:handle_request,_,_,_},
    %State{interested_of_me: false} = state) do
    {:stop,:protocol_error,state}
  end

  def handle_cast({:handle_request,index,begin,legnth},
    %State{choke: false, key: key={_,hash}} = state) do
      if Bitfield.check?(hash, index) do
        
        FileHandle.read(hash, index, begin, length)
        |> (&Transmitter.push_piece(key, index, begin, &1)).()

        send(self(), :send)
      end
    {:noreply, state}
  end

  def handle_cast({:piece,index,begin,block},) do
  
  end

  def handle_cast({:cancel,index,begin,legnth},) do
  
  end

  def handle_cast({:port,port},) do
  
  end

  defp do_has_index?(index, %State{bitfield: <<_::index, 1::1,_::bits>>})do
    true
  end

  defp do_has_index?(_,_), do: false
end

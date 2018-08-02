defmodule Bittorrent.Torrent.Server do
  use GenServer

  import Bittorrent
  import Bittorrent.Torrent
  require Via

  @first_piece_time 1_000

  Via.make()

  def start_link(%Struct{hash: hash} = torrent) do
    GenServer.start_link(__MODULE__, torrent, via(hash))
  end

  def get(hash), do: GenServer.call(via(hash),:get)

  def get_pieces_count(hash) do
    GenServer.call(via(hash),:get_pieces_count)
  end

 

  def init(%Strust{hash: hash, pieces_count: pieces_count} = torrent) do
    hash
    |> PeerDiscovery.get()
    |> Enum.each(&Acceptor.send(&1,hash))

    send_after(self(), :first_piece, @first_piece_time)

    {:ok, torrent}
  end

  def handle_call(:get,_,state), do: {:reply,state,state}

  def handle_call(:get_pieces_count,_,
    %Struct{pieces_count: pieces_count} = state) do
    {:reply,pieces_count,state}
  end

  def handle_info(:first_piece,%Struct{hash: hash} = state) do
    with [_|_] = list <- Swarm.Statistic.get(hash)
      |> Enum.filter(&elem(&1, 1) > 0 ) 
    do
      {piece, value} = Enum.random(list)

      

      {:noreply, %Struct{state | statistic: Map.put(stat,piece,{:ok,value})}}
    else
      _ -> 
        send_after(self(), :first_piece, @first_piece_time)
        {:noreply, state}
    end
  end

end

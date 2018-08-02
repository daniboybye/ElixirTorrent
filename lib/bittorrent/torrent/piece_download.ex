defmodule Bittorrent.Torrent.PieceDownload do
  use GenServer, restart: :transient

  @doc """
  key = {index,hash} 
  """

  @subpiece_length :math.pow(2,14)

  def start_link({index,hash,_} = args) do
    GenServer.start_link(__MODULE__,args,name: via({index,hash}) )
  end

  def init(args) do
    send(self(), :init)
    {:ok, args}
  end

  def handle_info(:init, {index,hash,length}) do
    make_subpieces(length)
    Swarm.interested(hash, index)
    
    {:noreply,}
  end

  defp make_subpieces(length, position \\ 0, res \\ [])

  defp make_subpieces(len, pos, res) when pos + @subpiece_length >= len do
    [{pos,len} | res]
  end

  defp make_subpieces(len, pos, res) do 
    [{pos,pos+@subpiece_length} | res]
  end

end
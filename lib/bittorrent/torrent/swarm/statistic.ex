defmodule Bittorrent.Torrent.Swarm.Statistic do
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

  def get(key), do: GenServer.call(via(key), :get)

  def make_zero(key, index) do
    GenServer.cast(via(key), {:make_zero, index)
  end

  def inc(key, index), do: GenServer.cast(via(key),{:inc,index})

  def init(count), do: {:ok, Enum.into(0..count-1,%{},&{&1,0})}

  def handle_call(:get,_,state), do: {:reply,state,state}

  def handle_cast({:make_zero,index}, state) do
    {:noreply, %{state | index => 0}}
  end

  def handle_cast({:inc, index},state) do
    {:noreply, 
    Map.update!(state,index, &if is_integer(&1) do &1+1 else &1 end)}
  end

end
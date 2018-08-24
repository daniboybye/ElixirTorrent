defmodule Torrent.PiecesStatistic do
  use GenServer, restart: :transient

  require Via
  Via.make()

  @spec start_link(Torrent.t()) :: GenServer.on_start()
  def start_link(%Torrent{hash: hash, last_index: index}) do
    GenServer.start_link(__MODULE__, index, name: via(hash))
  end

  @spec get_random(Torrent.hash()) :: Torrent.index() | nil
  def get_random(hash), do: GenServer.call(via(hash), :random)

  @spec get_rare(Torrent.hash()) :: Torrent.index() | nil
  def get_rare(hash), do: GenServer.call(via(hash), :rare)

  @spec make_zero(Torrent.hash(), Torrent.index()) :: :ok
  def make_zero(hash, index) do
    GenServer.cast(via(hash), {:do_make_zero, index})
  end

  @spec make_priority(Torrent.hash(), Torrent.index()) :: :ok
  def make_priority(hash, index) do
    GenServer.cast(via(hash), {:do_make_priority, index})
  end

  @spec inc(Torrent.hash(), Torrent.index()) :: :ok
  def inc(hash, index), do: GenServer.cast(via(hash), {:do_inc, index})

  @spec update(Torrent.hash(), Torrent.bitfield(), non_neg_integer()) :: :ok
  def update(hash, bitfield, size) do
    GenServer.cast(via(hash), {:update, bitfield, size})
  end

  @spec delete(Torrent.hash(), Torrent.index()) :: :ok
  def delete(hash, index) do
    GenServer.cast(via(hash), {:delete, index})
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash), do: GenServer.stop(via(hash))

  def init(count), do: {:ok, Enum.into(0..count, %{}, &{&1, 0})}

  def handle_call(:random, _, state), do: do_get(state, &random/1)

  def handle_call(:rare, _, state), do: do_get(state, &rare/1)

  defp do_get(state, algorithm) do
    state
    |> Enum.filter(&(elem(&1, 1) > 0))
    |> Enum.shuffle()
    |> case do
      [] ->
        {:reply, nil, state}

      list ->
        index = algorithm.(list) |> elem(0)
        {:reply, index, Map.delete(state, index)}
    end
  end

  defp random([x | _]), do: x

  defp rare(list) do
    with nil <- Enum.find(list, &(elem(&1, 1) === :priority)) do
      list
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(4)
      |> Enum.random()
    end
  end

  def handle_cast({:delete, index}, state) do
    {:noreply, Map.delete(state, index)}
  end

  def handle_cast({:update, bitfield, size}, state) do
    {:noreply, do_update(state, 0, size, bitfield)}
  end

  def handle_cast({:do_inc, index}, state) do
    {:noreply, do_inc(state, index)}
  end

  def handle_cast({:do_make_zero, index}, state) do
    {:noreply, Map.put(state, index, 0)}
  end

  def handle_cast({:do_make_priority, index}, state) do
    {:noreply, Map.put(state, index, :priority)}
  end

  defp do_update(state, index, size, _) when index == size, do: state

  defp do_update(state, index, size, <<1::1, tail::bits>>) do
    state
    |> do_inc(index)
    |> do_update(index + 1, size, tail)
  end

  defp do_update(state, index, size, <<_::1, tail::bits>>) do
    do_update(state, index + 1, size, tail)
  end

  defp do_inc(state, index) do
    with %{^index => x} when is_integer(x) <- state do
      %{state | index => x + 1}
    end
  end
end

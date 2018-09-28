defmodule Torrent.PiecesStatistic do
  use GenServer, restart: :transient

  require Via
  Via.make()

  @type index :: Torrent.index() | nil
  @typep element :: {Torrent.index(), non_neg_integer() | :priority | {:allowed_fast, pos_integer()} }

  @spec start_link(Torrent.t()) :: GenServer.on_start()
  def start_link(%Torrent{hash: hash, last_index: index}) do
    GenServer.start_link(__MODULE__, index, name: via(hash))
  end

  @spec get_random(Torrent.hash()) :: index()
  def get_random(hash), do: GenServer.call(via(hash), :random)

  @spec get_rare(Torrent.hash()) :: index()
  def get_rare(hash), do: GenServer.call(via(hash), :rare)

  @spec make_zero(Torrent.hash(), Torrent.index()) :: :ok
  def make_zero(hash, index) do
    GenServer.cast(via(hash), {:make_zero, index})
  end

  @spec make_priority(Torrent.hash(), Torrent.index()) :: :ok
  def make_priority(hash, index) do
    GenServer.cast(via(hash), {:make_priority, index})
  end

  @spec inc(Torrent.hash(), Torrent.index()) :: :ok
  def inc(hash, index), do: GenServer.cast(via(hash), {:inc, index})

  @spec inc_all(Torrent.hash()) :: :ok
  def inc_all(hash), do: GenServer.cast(via(hash), :inc_all)

  @spec update(Torrent.hash(), Torrent.bitfield(), non_neg_integer()) :: :ok
  def update(hash, bitfield, size) do
    GenServer.cast(via(hash), {:update, bitfield, size})
  end

  @spec allowed_fast(Torrent.hash(), Torrent.index()) :: :ok
  def allowed_fast(hash, index) do
    GenServer.cast(via(hash),{:allowed_fast, index})
  end
  
  @spec delete(Torrent.hash(), Torrent.index()) :: :ok
  def delete(hash, index) do
    GenServer.cast(via(hash), {:delete, index})
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash), do: GenServer.stop(via(hash))

  def init(count), do: {:ok, Enum.into(0..count, %{}, &{&1, 0})}

  def handle_call(_,_, x) when x == %{}, do: {:reply, nil, %{}}

  def handle_call(:random, _, state), do: do_get(state, &random/1)

  def handle_call(:rare, _, state), do: do_get(state, &rare/1)

  # tuple > atom !!!
  defp do_get(state, algorithm) do
    state
    |> Enum.shuffle
    |> Enum.max
    |> case do
      {index, {:allowed_fast, _}} ->
        index
      {index, :priority} ->
        index
      {_, x} when is_integer(x) ->
        state
        |> Enum.reject(&(elem(&1, 1) == 0))
        |> algorithm.()
      end
    |> (&{:reply, &1, Map.delete(state, &1)}).()
  end

  @spec random(list(element())) :: index()
  defp random([]), do: nil

  defp random(list), do: Enum.random(list) |> elem(0)

  @spec rare(list(element())) :: index()
  defp rare([]), do: nil

  defp rare(list) do
    list
    |> List.keysort(1)
    |> Enum.take(10)
    |> random
  end

  def handle_cast({:delete, index}, state) do
    {:noreply, Map.delete(state, index)}
  end

  def handle_cast({:update, bitfield, size}, state) do
    {:noreply, do_update(state, 0, size, bitfield)}
  end

  def handle_cast({:inc, index}, state) do
    {:noreply, do_inc(state, index)}
  end

  def handle_cast(:inc_all, state) do
    {
      :noreply,
      Enum.into(state, %{}, fn
        {k, v} when is_integer(v) -> {k, v + 1}
        x -> x
      end)
    }
  end

  def handle_cast({:make_zero, index}, state) do
    {:noreply, Map.put(state, index, 0)}
  end

  def handle_cast({:make_priority, index}, state) do
    {:noreply, Map.put(state, index, :priority)}
  end

  def handle_cast({:allowed_fast, index}, state) do
    case Map.get(state, index) do
      nil ->
        {:noreply, state}
      {:allowed_fast, x} ->
        {:noreply, Map.put(state, index, {:allowed_fast, x+1})}
      _ ->
        {:noreply, Map.put(state, index, {:allowed_fast, 1})}
    end
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

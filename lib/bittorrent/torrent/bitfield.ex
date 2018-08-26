defmodule Torrent.Bitfield do
  use GenServer

  require Via
  Via.make()

  @spec start_link(Torrent.t()) :: GenServer.on_start()
  def start_link(%Torrent{hash: hash, last_index: index}) do
    GenServer.start_link(__MODULE__, index + 1, name: via(hash))
  end

  @spec make(pos_integer()) :: Torrent.bitfield()
  def make(count) do
    count
    |> size()
    |> (&List.duplicate(0, &1)).()
    |> :binary.list_to_bin()
  end

  @spec get(Torrent.hash()) :: Torrent.bitfield()
  def get(hash), do: GenServer.call(via(hash), :get)

  @spec up(Torrent.hash(), Torrent.index()) :: :ok
  def up(hash, index), do: GenServer.cast(via(hash), {1,index})

  @spec down(Torrent.hash(), Torrent.index()) :: :ok
  def down(hash, index), do: GenServer.cast(via(hash), {0,index})

  @spec check?(Torrent.hash(), Torrent.index()) :: boolean()
  def check?(hash, index), do: GenServer.call(via(hash), index)

  def init(count), do: {:ok, __MODULE__.make(count)}

  def handle_call(:get, _, bitfield) do
    {:reply, bitfield, bitfield}
  end

  def handle_call(index, _, state) do
    <<_::bits-size(index), x::1, _::bits>> = state
    {:reply, x == 1, state}
  end

  def handle_cast({x, index}, state) do
    <<prefix::bits-size(index), _::1, postfix::bits>> = state
    {:noreply, <<prefix::bits, x::1, postfix::bits>>}
  end

  defp size(pieces_count) do
    (pieces_count / 8)
    |> Float.ceil()
    |> trunc()
  end
end

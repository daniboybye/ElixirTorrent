defmodule Torrent.FileHandle.Piece do
  @enforce_keys [:hash, :offset, :files, :length]
  defstruct [:hash, :offset, :files, :length]
  # offset: offset from the beginning of the first file

  use GenServer
  use Via

  alias Torrent.{Bitfield, PiecesStatistic}

  @timeout_hibernate 45 * 1_000

  # @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(key, piece) do
    GenServer.start_link(
      __MODULE__,
      piece,
      name: via(key)
    )
  end

  def child_spec(keyword) do
    key = {index, _} = Keyword.fetch!(keyword, :key)
    piece = Keyword.fetch!(keyword, :piece)
    %{id: {__MODULE__, index}, start: {__MODULE__, :start_link, [key, piece]}}
  end

  def key(hash, index), do: {index, hash}

  defp vk(hash, index), do: via(key(hash, index))

  @spec check?(Torrent.hash(), Torrent.index()) :: boolean()
  def check?(hash, index) do
    if flag = GenServer.call(vk(hash, index), :check, 5 * 60 * 1_000) do
      PiecesStatistic.set(hash, index, :complete)
      Bitfield.up(hash, index)
    else
      PiecesStatistic.set(hash, index, nil)
      Bitfield.down(hash, index)
    end

    flag
  end

  @spec read(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          (() -> binary())
  def read(hash, index, begin, length) do
    GenServer.call(vk(hash, index), {:read, begin, length}, 2 * 60 * 1_000)
  end

  @spec write(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def write(hash, index, begin, block) do
    GenServer.cast(vk(hash, index), {:write, begin, block})
  end

  def init(piece), do: {:ok, piece}

  def handle_call(:check, _, piece) do
    block = do_read(piece.offset, piece.length, piece.files)
    res = piece.hash === :crypto.hash(:sha, block)
    {:reply, res, piece, @timeout_hibernate}
  end

  def handle_call({:read, begin, length}, _, piece) do
    fun = fn -> do_read(piece.offset + begin, length, piece.files) end
    {:reply, fun, piece, @timeout_hibernate}
  end

  def handle_cast({:write, begin, block}, piece) do
    do_write(piece.offset + begin, piece.files, block)
    {:noreply, piece, @timeout_hibernate}
  end

  def handle_info(:timeout, piece),
  do: {:noreply, piece, :hibernate}

  defp do_read(offset, length, files, res \\ <<>>)

  defp do_read(_, _, [], res), do: res

  defp do_read(_, 0, _, res), do: res

  defp do_read(offset, length, [{pid, _} | files], res) do
    {:ok, block} = :file.pread(pid, {:bof, offset}, length)
    do_read(0, length - byte_size(block), files, res <> block)
  end

  defp do_write(_, _, <<>>), do: :ok

  defp do_write(offset, [{pid, len} | files], bin) do
    k = min(byte_size(bin), len - offset)
    <<bytes_for_writing::bytes-size(k), bin::binary>> = bin

    :ok = :file.pwrite(pid, {:bof, offset}, bytes_for_writing)
    do_write(0, files, bin)
  end
end

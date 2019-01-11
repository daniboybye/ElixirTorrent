defmodule Torrent.FileHandle.Piece do
  @enforce_keys [:hash, :offset, :files, :length]
  defstruct [:hash, :offset, :files, :length]
  # offset: offset from the beginning of the first file

  use GenServer
  use Via

  alias Torrent.{Bitfield, PiecesStatistic, Model}

  @timeout_hibernate 30 * 1_000

  def start_link({_, key} = arg) do
    GenServer.start_link(__MODULE__, arg, name: via(key))
  end

  def child_spec({_, {index, _}} = arg) do
    %{id: {__MODULE__, index}, start: {__MODULE__, :start_link, [arg]}}
  end

  def key(hash, index), do: {index, hash}

  defp vk(hash, index), do: via(key(hash, index))

  @spec check?(Torrent.hash(), Torrent.index()) :: boolean()
  def check?(hash, index) do
    GenServer.call(vk(hash, index), {:check?, hash, index}, 2 * 60 * 1_000)
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

  def init({piece, key}), do: {:ok, piece, {:continue, {:check, key}}}

  def handle_continue({:check, {index, torrent_hash}}, piece) do
    with x when x in [:complete, :processing] <- PiecesStatistic.get_status(torrent_hash, index),
         do: do_check(torrent_hash, index, piece)

    {:noreply, piece, :hibernate}
  end

  def handle_call({:check?, hash, index}, _, piece),
    do: {:reply, do_check(hash, index, piece), piece, @timeout_hibernate}

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

  defp do_check(torrent_hash, index, piece) do
    block = do_read(piece.offset, piece.length, piece.files)
    res = piece.hash === :crypto.hash(:sha, block)

    if res do
      Model.downloaded_piece(torrent_hash, index)
      PiecesStatistic.set(torrent_hash, index, :complete)
      Bitfield.up(torrent_hash, index)
    else
      PiecesStatistic.set(torrent_hash, index, nil)
      Bitfield.down(torrent_hash, index)
    end

    res
  end
end

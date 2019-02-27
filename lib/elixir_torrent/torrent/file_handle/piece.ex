defmodule Torrent.FileHandle.Piece do
  @enforce_keys [:hash, :offset, :files, :length]
  defstruct [:hash, :offset, :files, :length]
  # offset: offset from the beginning of the first file

  use GenServer
  use Via

  alias Torrent.{PiecesStatistic, Model}

  @timeout_hibernate 30 * 1_000

  def start_link({_, key} = arg),
    do: GenServer.start_link(__MODULE__, arg, name: via(key))

  def key(hash, index), do: {index, hash}

  defp vk(hash, index), do: via(key(hash, index))

  @spec check?(Torrent.hash(), Torrent.index()) :: boolean()
  def check?(hash, index) do
    GenServer.call(vk(hash, index), {:check?, hash, index}, 60 * 1_000)
  end

  @spec read(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          (() -> {:ok, iodata()} | :error)
  def read(hash, index, begin, length),
    do: GenServer.call(vk(hash, index), {:read, begin, length})

  @spec write(Torrent.hash(), Torrent.index(), Torrent.begin(), binary()) :: :ok
  def write(hash, index, begin, block),
    do: GenServer.cast(vk(hash, index), {:write, begin, block})

  def init({piece, key}), do: {:ok, piece, {:continue, {:check, key}}}

  def handle_continue({:check, {index, hash}}, piece) do
    if PiecesStatistic.get_status(hash, index) in [:complete, :processing] do
      do_check(hash, index, piece)
    end

    {:noreply, piece, :hibernate}
  end

  def handle_call({:check?, hash, index}, _, piece),
    do: {:reply, do_check(hash, index, piece), piece, @timeout_hibernate}

  def handle_call({:read, begin, length}, _, piece) do
    offset = begin + piece.offset
    files = piece.files
    fun = fn -> do_read(offset, length, files) end
    {:reply, fun, piece, @timeout_hibernate}
  end

  def handle_cast({:write, begin, block}, piece) do
    do_write(piece.offset + begin, piece.files, block)
    {:noreply, piece, @timeout_hibernate}
  end

  def handle_info(:timeout, piece),
    do: {:noreply, piece, :hibernate}

  defp do_read(offset, length, files, data \\ [])

  defp do_read(_, 0, _, data), do: {:ok, data}

  defp do_read(_, _, [], _), do: :error

  defp do_read(offset, length, [{_, file_length} | files], data) when offset >= file_length,
    do: do_read(offset - file_length, length, files, data)

  defp do_read(offset, length, [{pid, _} | files], data) do
    {:ok, block} = :file.pread(pid, {:bof, offset}, length)
    do_read(0, length - byte_size(block), files, [data, block])
  end

  defp do_write(_, _, <<>>), do: :ok

  defp do_write(offset, [{_, len} | files], bin) when offset >= len,
    do: do_write(offset - len, files, bin)

  defp do_write(offset, [{pid, len} | files], bin) do
    k = min(byte_size(bin), len - offset)
    <<bytes_for_writing::bytes-size(k), bin::binary>> = bin

    :ok = :file.pwrite(pid, {:bof, offset}, bytes_for_writing)
    do_write(0, files, bin)
  end

  defp do_check(torrent_hash, index, piece) do
    {:ok, block} = do_read(piece.offset, piece.length, piece.files)
    res = piece.hash === :crypto.hash(:sha, block)

    if res do
      Model.downloaded_piece(torrent_hash, index)
      PiecesStatistic.set(torrent_hash, index, :complete)
    else
      Model.hash_check_failure(torrent_hash, index)
      PiecesStatistic.set(torrent_hash, index, nil)
    end

    res
  end
end

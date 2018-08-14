defmodule Torrent.FileHandle do
  use GenServer

  require Via
  require Logger
  alias Torrent.{Struct, Bitfield}

  Via.make()

  @doc """
  FileHandle controls File.io_device() 
  and do not need to be closed manually
  """

  @spec start_link(Struct.t()) :: GenServer.on_start()
  def start_link(%Struct{hash: hash, struct: %{"info" => info}}) do
    GenServer.start_link(__MODULE__, info, name: via(hash))
  end

  @spec check?(Torrent.hash(), Torrent.index()) :: boolean()
  def check?(hash, index) do
    if res = GenServer.call(via(hash), {:check, index}, 120_000) do
      Bitfield.add_bit(hash, index)
    end

    res
  end

  @spec read(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.length()) :: binary()
  def read(hash, index, begin, length) do
    GenServer.call(via(hash), {:read, index, begin, length}, 120_000)
  end

  @spec read(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def write(key, index, begin, block) do
    GenServer.cast(via(key), {index, begin, block})
  end

  def init(%{"files" => files} = info) do
    state =
      files
      |> Enum.map(&Map.fetch!(&1, "length"))
      |> Enum.scan(&(&1 + &2))
      |> Enum.zip(Enum.map(files, &make_file/1))
      |> (&Map.put(info, "files", &1)).()

    Logger.info("allocate files")
    {:ok, state}
  end

  def init(%{"length" => length, "name" => name} = info) do
    state =
      %{"length" => length, "path" => [name]}
      |> make_file()
      |> (&Map.put(info, "files", [{length, &1}])).()

    Logger.info("allocate file")
    {:ok, state}
  end

  def handle_call(
        {:check, index},
        _,
        %{"files" => files, "piece length" => len, "pieces" => pieces} = state
      ) do
    {offset, files1} = offset_files(index, files, len)
    hash = binary_part(pieces, index * 20, 20)
    piece = do_read(offset, len, files1)
    {:reply, hash == :crypto.hash(:sha, piece), state}
  end

  def handle_call(
        {:read, index, begin, length},
        _,
        %{"files" => files, "piece length" => piece_len} = state
      ) do
    {offset, files1} = offset_files(index, files, piece_len, begin)
    {:reply, do_read(offset, length, files1), state}
  end

  def handle_cast({index, begin, block}, %{"files" => files, "piece length" => len} = state) do
    {offset, files1} = offset_files(index, files, len, begin)
    do_write(offset, files1, block)
    {:noreply, state}
  end

  defp offset_files(index, files, piece_len, offset \\ 0) do
    pos = index * piece_len + offset
    {left, right} = Enum.split_while(files, &(elem(&1, 0) <= pos))
    {pos - elem(List.last([{0, 0} | left]), 0), Keyword.values(right)}
  end

  defp do_read(offset, length, files, res \\ <<>>)

  defp do_read(_, _, [], res), do: res

  defp do_read(_, 0, _, res), do: res

  defp do_read(offset, length, [{pid, _} | files], res) do
    {:ok, block} = :file.pread(pid, {:bof, offset}, length)
    do_read(0, length - byte_size(block), files, res <> block)
  end

  defp do_write(_, _, <<>>), do: :ok

  defp do_write(offset, [{pid, len} | files], bin) do
    s = byte_size(bin)
    n = min(s, len - offset)
    :ok = :file.pwrite(pid, {:bof, offset}, binary_part(bin, 0, n))
    do_write(0, files, binary_part(bin, n, s - n))
  end

  defp make_file(%{"length" => length, "path" => path}) do
    name = Path.join([System.cwd!() | path])

    pid =
      case File.stat(name) do
        {:ok, %File.Stat{size: ^length}} ->
          File.open!(name, [:binary, :read, :write])

        {:ok, _} ->
          File.rm!(name)
          allocate_file(name, length)

        {:error, :enoent} ->
          allocate_file(name, length)
      end

    {pid, length}
  end

  defp allocate_file(name, length) do
    name
    |> Path.dirname()
    |> File.mkdir_p!()

    File.touch!(name)

    pid = File.open!(name, [:binary, :read, :write])
    :file.pwrite(pid, {:bof, length - 1}, <<0>>)

    pid
  end
end

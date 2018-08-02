defmodule Bittorent.Torrent.FileHandle do
  use GenServer

  import Bittorrent
  require Via

  Via.make()

  @doc """
  key = hash 

  FileHandle controls File.io_device() 
  and do not need to be closed manually
  """

  def start_link({key,args}) do 
    GenServer.start_link(__MODULE__, args, via(key))
  end

  def check_hash(key, index) do 
    GenServer.call(via(key), {:check, index})
  end
  
  def read(key, index, begin, length) do
    GenServer.call(via(key),{:read, index,begin,length})
  end

  def write(key, index, begin, block) do
    GenServer.cast(via(key), {index, begin, block})
  end

  def size(key), do: GenServer.call(via(key),:size)
  
  def init(info) do
    info["files"]
    |> Enum.map(&Map.fetch!(&1, "length"))
    |> Enum.scan(&(&1 + &2))
    |> Enum.zip(Enum.map(info["files"], &make_file/1))
    |> (& {:ok, Map.put(info, "files", &1)}).()
  end

  def handle_call(:size,_,%{"files" => files} = state) do
    size = files |> List.last() |> elem(0)
    {:reply,size, state}
  end

  def handle_call({:check, index}, _, %{"files" => files, 
    "piece length" => len, "pieces" => pieces} = state) do

    {offset, files1} = offset_files(index, files, len)
    hash = binary_part(pieces, index*20, 20)
    piece = do_read(offset,len,files1)
    res = hash === :crypto.hash(:sha, piece)
    {:reply, res, state}
  end

  def handle_call({:read,index,begin,length},_,
  %{"files" => files, "piece length" => piece_len} = state) do
    {offset, files1} = offset_files(index, files, piece_len, begin)
    res = do_read(offset, length, files)
    {:reply, res, state}
  end

  def handle_cast({index, begin, block},
    %{"files" => files, "piece length" => len} = state) do
    {offset, files1} = offset_files(index, files, len, begin)
    do_write(offset, files1, block)
    {:noreply, state}
  end

  defp offset_files(index, files, piece_len, offset // 0) do
    {left, right} = Enum.split_while(files, 
      fn {x,_} -> x <= index * piece_len + offset end)
    {
      index * piece_len - elem(List.last(left), 0),
      right 
      |> Enum.take_while(fn {x,_} -> x <= index * (piece_len + 1) end)
      |> Keyword.values()
    }
  end

  defp do_read(offset, length, files, res // <<>>)

  defp do_read(_,0,_,res), do: res

  defp do_read(offset, length, [{pid,_} | files] , res) do
    {:ok, block} = :file.pread(pid, {:bof,offset}, length)
    do_read(0,length - byte_size(block) ,files, res <> block)
  end

  defp do_write(_,_,<<>>), do: :ok

  defp do_write(offset,[{pid, len} | files], bin) do
    s = byte_size(bin)
    n = min(s, len - offset)
    :ok = :file.pwrite(pid,{:bof,offset}, n)
    do_write(0,files, binary_part(bin, n, s - n))
  end

  defp make_file(%{"length" => length, "path" => path}) do
    name = Path.join([System.cwd!() | path])

    pid = case File.stat(name) do
      {:ok, %File.Stat{size: length}} -> 
        File.open!(name,[:binary, :read, :write])
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

    pid = File.open!(name,[:binary, :read, :write])
    :file.pwrite(pid, {:bof, length - 1}, <<0>>)

    pid
  end
end
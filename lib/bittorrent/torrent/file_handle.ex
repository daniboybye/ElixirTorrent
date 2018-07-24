defmodule Bittorent.Torrent.FileHandle do
  use GenServer

  import Bittorrent
  require Via

  Via.make()

  @subpiece_size :math.pow(2,14)

  @doc """
  key = info_hash 
  """

  def start_link(key), do: GenServer.start_link(__MODULE__, key, via(key))

  def check_hash(key, index), do: GenServer.call(via(key), index)

  def save(key, index, begin, block) do
    GenServer.cast(via(key), {index, begin, block})
  end
  
  def init(key) do
    info = RegirstryTorrents.get_info(key)

    info["files"]
    |> Enum.map(&Map.fetch!(&1, "length"))
    |> Enum.scan(&(&1 + &2))
    |> Enum.zip(Enum.map(info["files"], &make_file/1))
    |> (& {:ok, Map.put(info, "files", &1)}).()
  end

  def terminate(_, %{"files" => files}) do
    Enum.each(files, fn {_,{pid,_}} -> File.close(pid) end)
  end

  def handle_call(index, _, %{"files" => files, 
    "piece length" => len, "pieces" => pieces} = state) do

    {offset, files} = offset_files(index, files, len)
    res = check(offset,len,files,binary_part(pices, index*20, 20))
    {:reply, res, state}
  end

  def handle_cast({index, begin, block},%{"files" => files} = state) do
    {offset, files} = offset_files(index, files, len, begin)
    do_save(offset, files, block)
    {:noreply, state}
  end

  defp offset_files(index, files, len, offset // 0) do
    {left, right} = Enum.split_while(files, 
      fn {x,_} -> x <= index * len + offset end)
    {
      index * len - elem(List.last(left), 0),
      right 
      |> Enum.take_while(fn {x,_} -> x <= index * (len + 1) end)
      |> Keyword.values()
    }
  end

  defp do_save(_,_,<<>>), do: :ok

  defp do_save(offset,[{pid, len} | files], bin) do
    s = byte_size(bin)
    n = min(s, len - offset)
    :file.pwrite(pid,{:bof,offset}, n)
    save(0,files, binary_part(bin, n, s - n)
  end

  defp check(offset, len, file, hash, bin // <<>>)

  defp check(_, _, [], hash, bin), do: hash == :crypto.hash(:sha, bin)

  defp check(offset, len, [{pid,_} | files], hash, bin) do
    tbin = :file.pread(pid,{:bof,offset},len)
    check(0,len - byte_size(pbin), files, bin <> tbin)
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
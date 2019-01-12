defmodule ElixirTorrent do
  def main(_), do: loop()

  def version, do: "ET0-1-0"

  defp loop do
    parse(IO.read(:line))
    loop()
  end

  defp parse(<<"download ", path::binary>>) do
    {:ok, pid} = Torrents.download(path)

    Task.start(fn -> info(Torrent.get_hash(pid)) end)
  end

  defp parse(_), do: nil

  defp info(hash) do
    Process.sleep(45_000)
    [name, speed, downloaded, size] = 
      Torrent.get(hash, [:name, :speed, :downloaded, :bytes_size])
    
    if downloaded === size do
      :normal
    else
      [
        name, 
        "download: #{speed.download} Kb/s",
      "upload: #{speed.upload} Kb/s",
      "#{Float.ceil(downloaded*100 / size)}%",
      "---------------------------------------"
      ]
      |>Enum.intersperse("\r\n")
      |> IO.puts()

      info(hash)
    end
  end

  defdelegate download(path), to: Torrents

  def get(pid, args \\ []) do
    Torrent.get_hash(pid)
    |> Torrent.get(args)
  end
end

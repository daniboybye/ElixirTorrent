defmodule Torrent.FileHandle do
  use Supervisor, type: :supervisor
  use Via

  alias __MODULE__.Piece
  alias Torrent.Model

  @doc """
  FileHandle controls File.io_device() 
  and do not need to be closed manually
  """

  @spec start_link(Torrent.hash()) :: Supervisor.on_start()
  def start_link(hash),
    do: Supervisor.start_link(__MODULE__, hash, name: via(hash))

  defdelegate check?(hash, index), to: Piece

  defdelegate read(hash, index, begin, length), to: Piece

  defdelegate write(hash, index, begin, block), to: Piece

  def init(hash) do
    [metadata, last_index, last_piece_length] =
      Model.get(hash, [:metadata, :last_index, :last_piece_length])

    all_files = init_files(metadata["info"])
    length = metadata["info"]["piece length"]
    pieces_hash = metadata["info"]["pieces"]

    last_piece =
      make_piece(
        last_index,
        last_piece_length,
        all_files,
        hash,
        pieces_hash
      )

    0..(last_index - 1)
    |> Enum.map(&make_piece(&1, length, all_files, hash, pieces_hash))
    |> (&[last_piece | &1]).()
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp make_piece(index, length, all_files, torrent_hash, pieces_hash) do
    {offset, files} = files_for_index(index, all_files, length)

    piece = %Piece{
      offset: offset,
      files: files,
      length: length,
      hash: binary_part(pieces_hash, index * 20, 20)
    }

    name = Piece.key(torrent_hash, index)

    Supervisor.child_spec({Piece, {piece, name}}, id: index)
  end

  defp init_files(%{"files" => files}) do
    files
    |> Enum.map(&Map.fetch!(&1, "length"))
    |> Enum.scan(&(&1 + &2))
    |> Enum.zip(Enum.map(files, &open_file/1))
  end

  defp init_files(%{"length" => length, "name" => name}) do
    [{length, open_file(%{"length" => length, "path" => [name]})}]
  end

  defp open_file(%{"length" => length, "path" => path}) do
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

  defp files_for_index(index, files, piece_len) do
    pos = index * piece_len
    {left, right} = Enum.split_while(files, &(elem(&1, 0) <= pos))
    {pos - elem(List.last([{0, 0} | left]), 0), Keyword.values(right)}
  end
end

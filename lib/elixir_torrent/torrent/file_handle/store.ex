defmodule Torrent.FileHandle.Store do
  @moduledoc """
  Publishes the immutable per-torrent file layout (paths + lengths).

  `Store` no longer opens the io_devices itself: OTP's `:raw` files can only be
  used by the process that opened them (`:not_on_controlling_process` otherwise),
  and the actual pread/pwrite calls are made from `Piece` processes (and the
  resume verify tasks), not from `Store`. So `Store` only does two things:

    * ensures every file exists on disk at its declared size (creates parent
      dirs, allocates a sparse file by writing a single byte at `length-1`,
      re-allocates if a stale wrong-size file is on disk), and
    * publishes the layout as `[{cumulative_end_offset, {path, length}}, ...]`
      into `:persistent_term`, so `Piece.init/1` and the resume verify tasks can
      derive any piece's file slice without a GenServer round-trip.

  Not opening the files here is what unlocks `:raw` in `Piece` (no `file_io_server`
  process per file, no serialized I/O through its mailbox).

  `Store` traps exits so `terminate/2` fires on supervisor shutdown and erases
  the published context. It holds no linked io_devices anymore, so it can't
  crash from a dying handle.
  """

  use GenServer
  use Via

  alias Torrent.{Model, PathLayout, FileHandle}

  @spec start_link(Torrent.hash()) :: GenServer.on_start()
  def start_link(hash),
    do: GenServer.start_link(__MODULE__, hash, name: via(hash))

  @impl true
  def init(hash) do
    # trap_exit so a supervisor shutdown runs terminate/2 and erases the
    # persistent_term entry — Store no longer owns io_devices, so this is
    # purely for graceful teardown.
    Process.flag(:trap_exit, true)

    [metadata, last_index, last_piece_length, download_dir] =
      Model.get(hash, [:metadata, :last_index, :last_piece_length, :download_dir])

    download_dir = download_dir || File.cwd!()

    context = %{
      all_files: init_files(metadata["info"], download_dir),
      # normal piece length; the final piece uses last_piece_length
      piece_length: metadata["info"]["piece length"],
      pieces_hash: metadata["info"]["pieces"],
      last_index: last_index,
      last_piece_length: last_piece_length
    }

    :persistent_term.put(FileHandle.context_key(hash), context)

    {:ok, hash}
  end

  @impl true
  def terminate(_reason, hash) do
    :persistent_term.erase(FileHandle.context_key(hash))
    :ok
  end

  # --- layout preparation ---

  defp init_files(%{"files" => files} = info, download_dir) do
    files
    |> Enum.map(&Map.fetch!(&1, "length"))
    |> Enum.scan(&(&1 + &2))
    |> Enum.zip(Enum.map(files, &ensure_file(info, &1, download_dir)))
  end

  defp init_files(%{"length" => length, "name" => name} = info, download_dir) do
    [{length, ensure_file(info, %{"length" => length, "path" => [name]}, download_dir)}]
  end

  defp ensure_file(info, %{"length" => length, "path" => path}, download_dir) do
    name =
      info
      |> PathLayout.layout_path(path)
      |> then(&Path.join([download_dir | &1]))

    case File.stat(name) do
      {:ok, %File.Stat{size: ^length}} ->
        :ok

      {:ok, _} ->
        File.rm!(name)
        allocate_file(name, length)

      {:error, :enoent} ->
        allocate_file(name, length)
    end

    {name, length}
  end

  defp allocate_file(name, length) do
    name
    |> Path.dirname()
    |> File.mkdir_p!()

    File.touch!(name)

    if length > 0 do
      {:ok, fd} = :file.open(name, [:binary, :raw, :read, :write])
      :ok = :file.pwrite(fd, length - 1, <<0>>)
      :ok = :file.close(fd)
    end

    :ok
  end
end

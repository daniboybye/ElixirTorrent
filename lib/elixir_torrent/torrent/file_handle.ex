defmodule Torrent.FileHandle do
  @moduledoc """
  Supervisor for torrent disk I/O: shared file store and lazy per-piece writers.
  """

  use Supervisor, type: :supervisor
  use Via

  alias __MODULE__.{Piece, Store, PieceSupervisor}

  @doc """
  FileHandle owns the File.io_device()s for a torrent and hands out per-piece
  read/write/verify access.

  Historically this supervisor eagerly started ONE `Piece` GenServer per piece
  (`0..last_index`) at torrent load. A single large torrent has tens of
  thousands of pieces, so a busy node accumulated ~19k idle piece processes that
  only hibernated. They were bounded (not a leak) but a hard scale ceiling and
  unlike libtorrent/qBittorrent, which keep piece state in compact structures.

  Now pieces are started **lazily / on demand**:

    * `Store` opens every file's io_device ONCE and publishes the small,
      immutable "context" (all_files/piece_length/pieces_hash/last_index/…)
      needed to derive any piece's slice. It is the owner process for the shared
      io_devices and lives for the torrent's lifetime.
    * `PieceSupervisor` is a `DynamicSupervisor` that starts a `Piece` process
      the first time a given piece is read/written/checked and reuses it while
      it stays alive.
    * A `Piece` **terminates** after an idle timeout instead of hibernating
      forever, so completed/untouched pieces stop holding a process. The next
      access transparently restarts it from `context/1`.

  Children use `:rest_for_one`: if `Store` crashes (and its io_devices die with
  it) the `PieceSupervisor` is torn down too, so no `Piece` can keep reading
  through a stale, dead io_device — the next access rebuilds against the freshly
  reopened handles.
  """

  @spec start_link(Torrent.hash()) :: Supervisor.on_start()
  def start_link(hash),
    do: Supervisor.start_link(__MODULE__, hash, name: via(hash))

  defdelegate check?(hash, index), to: Piece
  defdelegate check?(hash, index, context), to: Piece

  defdelegate read(hash, index, begin, length), to: Piece

  defdelegate write(hash, index, begin, block), to: Piece
  defdelegate flush(hash, index), to: Piece

  def init(hash) do
    children = [
      # Store must come first: it opens the io_devices and publishes the shared
      # context. PieceSupervisor (and every Piece) depends on that context, so
      # :rest_for_one guarantees pieces are wiped and rebuilt if Store restarts.
      {Store, hash},
      {PieceSupervisor, hash}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  `:persistent_term` key under which `Store` publishes the shared context.

  We use `:persistent_term` (not a GenServer call per access) because the
  context is written once per torrent load and then read on the hot path from
  arbitrary caller processes — piece starts and the resume verify tasks — with
  no copying. The trade-off is that writing/erasing it triggers a global GC
  scan, which is why `Store` only touches it on load and teardown.
  """
  @spec context_key(Torrent.hash()) :: {module(), Torrent.hash()}
  def context_key(hash), do: {__MODULE__, hash}

  @doc "Shared, immutable per-torrent context published by `Store`, or nil during teardown."
  @spec context(Torrent.hash()) :: map() | nil
  def context(hash), do: :persistent_term.get(context_key(hash), nil)

  @doc "Via name of the per-torrent `Piece` DynamicSupervisor."
  @spec piece_supervisor(Torrent.hash()) :: GenServer.name()
  def piece_supervisor(hash), do: PieceSupervisor.name(hash)

  @doc """
  Derive a `%Piece{}` for `index` purely from the shared context (no I/O and no
  process). Used both when lazily starting a `Piece` and by the resume verify
  path, which re-hashes on-disk pieces without ever starting a `Piece` process.

  Returns `:error` when the context is gone (torrent teardown race).
  """
  @spec piece_struct(Torrent.hash(), Torrent.index()) :: {:ok, Piece.t()} | :error
  def piece_struct(hash, index) do
    case context(hash) do
      nil ->
        :error

      ctx ->
        this_length = piece_length_at(ctx, index)
        {offset, files} = files_for_index(index, ctx.all_files, ctx.piece_length, this_length)

        hash =
          if ctx.kind == :v2 do
            <<0::160>>
          else
            binary_part(ctx.pieces_hash, index * 20, 20)
          end

        {:ok,
         %Piece{
           offset: offset,
           files: files,
           length: this_length,
           hash: hash
         }}
    end
  end

  defp piece_length_at(%{piece_lengths: lengths, last_index: last, last_piece_length: lpl}, index)
       when is_list(lengths) do
    if index == last, do: lpl, else: Enum.at(lengths, index)
  end

  defp piece_length_at(%{piece_length: pl, last_index: last, last_piece_length: lpl}, index) do
    if index == last, do: lpl, else: pl
  end

  @doc """
  Hash-verify a piece straight off disk, WITHOUT starting a `Piece` process.

  This is how resume checks on-disk pieces: it reuses the exact `Piece.check/4`
  (formerly `do_check`) side effects — `Model`/`PiecesStatistic` updates and the
  `:resume`/`:download` logging distinction — but runs in a plain (transient)
  caller/task instead of spinning up one long-lived process per piece.
  """
  @spec verify(Torrent.hash(), Torrent.index(), :download | :resume) :: boolean()
  def verify(hash, index, context) do
    case piece_struct(hash, index) do
      {:ok, piece} -> Piece.check(hash, index, piece, context)
      :error -> false
    end
  end

  # Slice `all_files` down to the {io_device, length} tuples spanning `index`,
  # plus the byte offset of the piece inside the first of those files. Pure list
  # arithmetic over the cumulative end-offsets Store built with Enum.scan/2.
  #
  # `piece_len` is the NORMAL piece length (used to locate the piece's start),
  # while `length` is THIS piece's real length (normal, or last_piece_length for
  # the final piece), used to find where the piece ends.
  defp files_for_index(index, files, piece_len, length) do
    begin_offset = index * piece_len

    # right are the files whose end is before begin_offset
    {left, right} = Enum.split_while(files, &(elem(&1, 0) <= begin_offset))

    offset_from_first_file = begin_offset - elem(List.last([{0, nil} | left]), 0)

    {files, [last_file | _]} = Enum.split_while(right, &(elem(&1, 0) < begin_offset + length - 1))

    {offset_from_first_file, normalize_file_entries(files ++ [last_file])}
  end

  defp normalize_file_entries(entries) do
    Enum.map(entries, fn
      {_end, {:gap, gap_length}} -> {:gap, gap_length}
      {_end, {path, file_length}} -> {path, file_length}
    end)
  end
end

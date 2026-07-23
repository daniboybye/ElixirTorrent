defmodule Torrent.FileHandle.Piece do
  @enforce_keys [:hash, :offset, :files, :length]
  defstruct [:hash, :offset, :files, :length, pending_writes: %{}]
  # offset: offset from the beginning of the first file

  # `files` is the durable spec `[{path, length}]` as built by Store. In a
  # running Piece process the process state replaces it in-place with the
  # opened raw fds `[{fd, length}]` (see init/1). The standalone `check/4`
  # opens/closes fds locally, so it always sees `files` as paths.
  @type t :: %__MODULE__{
          hash: <<_::160>>,
          offset: non_neg_integer(),
          files: [{Path.t() | :file.fd(), Torrent.length()}],
          length: Torrent.length()
        }

  # File open modes for raw per-piece handles: `:raw` bypasses `file_io_server`
  # (no GenServer per file, no serialized I/O through its mailbox), at the cost
  # that only the opener process may pread/pwrite them — hence why we open in
  # Piece.init and close in terminate, not in Store.
  @file_modes [:binary, :raw, :read, :write]

  use GenServer
  use Via

  alias Torrent.{PiecesStatistic, Model, FileHandle}

  require Logger

  # Idle window before the process terminates (was: hibernate forever). Any
  # read/write/check resets it. When it fires the piece process exits and the
  # next access lazily restarts it — completed/untouched pieces stop holding a
  # process entirely.
  @timeout_idle 30 * 1_000
  # Coalesce subpiece writes before hitting the disk. BitTorrent blocks are 16 KiB;
  # pipelined requests often fill a piece in bursts — flushing each block separately
  # costs one pwrite syscall per block. Batch contiguous ranges up to this ceiling
  # (libtorrent-style write cache) so a full piece typically needs far fewer syscalls.
  @flush_threshold 64 * 1024

  # `:temporary`: a piece carries no durable in-memory state (every write is
  # flushed synchronously to the io_device, and the struct is re-derivable from
  # FileHandle.context/1), so idle self-termination and rare crashes are both
  # handled by lazy restart on next access rather than a supervisor restart.
  def child_spec(args) do
    %{
      id: __MODULE__,
      restart: :temporary,
      start: {__MODULE__, :start_link, args}
    }
  end

  @spec start_link(Torrent.hash(), Torrent.index()) :: GenServer.on_start()
  def start_link(hash, index) do
    case FileHandle.piece_struct(hash, index) do
      {:ok, piece} -> GenServer.start_link(__MODULE__, piece, name: via(key(hash, index)))
      # Context vanished (torrent teardown between start request and start) —
      # tell the DynamicSupervisor to ignore this child.
      :error -> :ignore
    end
  end

  def key(hash, index), do: {index, hash}

  @spec check?(Torrent.hash(), Torrent.index(), :download | :resume) :: boolean()
  def check?(hash, index, context \\ :download) do
    call(hash, index, {:check?, hash, index, context}, 60 * 1_000)
  end

  @spec read(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          {:ok, binary()} | :error
  def read(hash, index, begin, length),
    do: call(hash, index, {:read, begin, length}, 5_000)

  @spec flush(Torrent.hash(), Torrent.index()) :: :ok
  def flush(hash, index) do
    case GenServer.whereis(via(key(hash, index))) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  @spec write(Torrent.hash(), Torrent.index(), Torrent.begin(), binary()) :: :ok
  def write(hash, index, begin, block) do
    # Cast to the concrete pid (not the via name) so a rename race can't misroute
    # the block. A dropped cast (piece stopped in the microsecond gap) is not
    # data loss: writes flush synchronously, active downloads keep the piece
    # alive between blocks, and the mandatory post-download hash check
    # (Downloads.Piece → check?/3) re-downloads any piece whose bytes are short.
    GenServer.cast(ensure_started(hash, index), {:write, begin, block})
  end

  @doc """
  Standalone hash verification (no process). Same side effects as an in-process
  `{:check?, …}` — used by `FileHandle.verify/3` for resume.
  """
  @spec check(Torrent.hash(), Torrent.index(), t(), :download | :resume) :: boolean()
  def check(hash, index, %__MODULE__{files: paths} = piece, context) do
    # Standalone caller (a resume Task): open raw fds locally, hash, close.
    # `paths` are strings straight from Store's context.
    fds = open_files(paths)

    try do
      hash_check(hash, index, piece, fds, context)
    after
      close_files(fds)
    end
  end

  def init(%__MODULE__{files: paths} = piece) do
    # `paths` from FileHandle.piece_struct/2 is [{path, length}]. Open raw fds
    # owned by this GenServer and replace `files` with [{fd, length}] so
    # hot-path read/write/check can pread/pwrite directly.
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{piece | files: open_files(paths)}, @timeout_idle}
  end

  def terminate(_reason, %__MODULE__{files: fds} = piece) do
    _ = flush_pending_writes(piece)
    close_files(fds)
  end

  def handle_call(:flush, _, piece) do
    piece = flush_pending_writes(piece)
    {:reply, :ok, piece, @timeout_idle}
  end

  def handle_call({:check?, hash, index, context}, _, piece) do
    piece = flush_pending_writes(piece)
    {:reply, hash_check(hash, index, piece, piece.files, context), piece, @timeout_idle}
  end

  def handle_call({:read, begin, length}, _, piece) do
    piece = flush_pending_writes(piece)
    # Raw fds are owned by this GenServer, so the pread has to run here.
    {:reply, do_read(begin + piece.offset, length, piece.files), piece, @timeout_idle}
  end

  def handle_cast({:write, begin, block}, piece) do
    piece = buffer_write(piece, begin, block)
    piece = maybe_flush_writes(piece)
    {:noreply, piece, @timeout_idle}
  end

  # Idle: flush any coalesced blocks, then terminate. The receive-timeout only
  # fires with an empty mailbox, so no cast can race a partial buffer here.
  def handle_info(:timeout, piece) do
    piece = flush_pending_writes(piece)
    {:stop, :normal, piece}
  end

  # --- lazy start / call plumbing ---

  # Start the piece if absent, reuse if present. The via-name registration makes
  # start-or-lookup atomic: if two callers race, one wins and the loser gets
  # {:error, {:already_started, pid}} — guaranteeing a single process per piece,
  # which is what serializes writes (cast) against reads/checks (call).
  defp ensure_started(hash, index) do
    case Registry.lookup(Registry, {key(hash, index), __MODULE__}) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               FileHandle.piece_supervisor(hash),
               {__MODULE__, [index]}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          # Context gone: mirror a call to a missing process so the caller unwinds
          # exactly as it would have before (torrent teardown only).
          :ignore -> exit({:noproc, {__MODULE__, :ensure_started, [hash, index]}})
        end
    end
  end

  defp call(hash, index, msg, timeout) do
    pid = ensure_started(hash, index)

    try do
      GenServer.call(pid, msg, timeout)
    catch
      # The piece idle-terminated between lookup and call (or was shutting down).
      # Restart it and retry once — this is the steady-state path for a piece
      # that has been idle past @timeout_idle.
      :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
        GenServer.call(ensure_started(hash, index), msg, timeout)
    end
  end

  # --- unchanged I/O + verification ---

  defp do_read(offset, length, files, data \\ [])

  defp do_read(_, 0, _, data), do: {:ok, IO.iodata_to_binary(data)}

  defp do_read(_, _, [], _), do: :error

  defp do_read(offset, length, [{_, file_length} | files], data) when offset >= file_length,
    do: do_read(offset - file_length, length, files, data)

  defp do_read(offset, length, [{pid, _} | files], data) do
    # Raw fds require an integer offset (they reject the `{:bof, N}` form that
    # non-raw file_io_server handles accept).
    {:ok, block} = :file.pread(pid, offset, length)
    do_read(0, length - byte_size(block), files, [data, block])
  end

  defp buffer_write(%__MODULE__{pending_writes: pending} = piece, begin, block) do
    %__MODULE__{piece | pending_writes: Map.put(pending, begin, block)}
  end

  defp maybe_flush_writes(%__MODULE__{pending_writes: pending} = piece) do
    bytes = Enum.reduce(pending, 0, fn {_, bin}, acc -> acc + byte_size(bin) end)

    if bytes >= @flush_threshold do
      flush_pending_writes(piece)
    else
      piece
    end
  end

  defp flush_pending_writes(%__MODULE__{pending_writes: pending} = piece)
       when map_size(pending) == 0,
       do: piece

  defp flush_pending_writes(%__MODULE__{pending_writes: pending} = piece) do
    pending
    |> Enum.sort()
    |> merge_contiguous_writes()
    |> Enum.each(fn {begin, block} ->
      do_write(piece.offset + begin, piece.files, block)
    end)

    %__MODULE__{piece | pending_writes: %{}}
  end

  # Turn sorted {begin, block} pairs into merged contiguous ranges so one pwrite
  # covers each run of adjacent subpieces (out-of-order arrivals start a new run).
  defp merge_contiguous_writes([]), do: []

  defp merge_contiguous_writes(sorted) do
    Enum.reduce(sorted, [], fn {begin, block}, acc ->
      case acc do
        [] ->
          [{begin, block}]

        [{prev_begin, prev_block} | rest] ->
          prev_end = prev_begin + byte_size(prev_block)

          if begin == prev_end do
            [{prev_begin, prev_block <> block} | rest]
          else
            [{begin, block}, {prev_begin, prev_block} | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp do_write(_, _, <<>>), do: :ok

  defp do_write(offset, [{_, len} | files], bin) when offset >= len,
    do: do_write(offset - len, files, bin)

  defp do_write(offset, [{pid, len} | files], bin) do
    k = min(byte_size(bin), len - offset)
    <<bytes_for_writing::bytes-size(^k), bin::binary>> = bin

    :ok = :file.pwrite(pid, offset, bytes_for_writing)
    do_write(0, files, bin)
  end

  defp open_files(paths) do
    Enum.map(paths, fn {path, length} ->
      {:ok, fd} = :file.open(path, @file_modes)
      {fd, length}
    end)
  end

  defp close_files(fds) do
    Enum.each(fds, fn {fd, _} -> :ok = :file.close(fd) end)
  end

  defp hash_check(torrent_hash, index, piece, fds, context) do
    {:ok, block} = do_read(piece.offset, piece.length, fds)
    res = piece.hash === :crypto.hash(:sha, block)

    hash_hex = Torrent.hex_encoded_hash(torrent_hash)

    if res do
      # A completed download verifying is a real event worth :info; the startup
      # resume scan re-hashes every on-disk piece and would flood the log.
      log_verify(context, "[piece_verify] hash=#{hash_hex} index=#{index} result=ok", :ok)

      Model.downloaded_piece(torrent_hash, index)
      PiecesStatistic.set(torrent_hash, index, :complete)
    else
      # During :resume a mismatch just means the piece isn't on disk yet — not a
      # failure. During :download it means a peer served corrupt data, which is a
      # genuine warning (and the caller drops that block/peer).
      if context == :download do
        invalidate_piece_on_disk(piece, fds)
      end

      log_verify(
        context,
        "[piece_verify] hash=#{hash_hex} index=#{index} result=#{if context == :resume, do: "absent", else: "fail"} expected_len=#{piece.length} read_bytes=#{byte_size(block)}",
        :fail
      )

      Model.hash_check_failure(torrent_hash, index)
      PiecesStatistic.set(torrent_hash, index, nil)
    end

    res
  end

  defp log_verify(:download, msg, :ok), do: Logger.info(msg)
  defp log_verify(:download, msg, :fail), do: Logger.warning(msg)
  defp log_verify(:resume, msg, _outcome), do: Logger.debug(msg)

  # Wipe a failed piece so the next download attempt cannot re-hash stale bytes.
  @zero_chunk 256 * 1024

  defp invalidate_piece_on_disk(%__MODULE__{offset: offset, length: length}, fds) do
    zero_range(offset, length, fds)
  end

  defp zero_range(_offset, 0, _fds), do: :ok

  defp zero_range(offset, remaining, fds) do
    chunk = min(remaining, @zero_chunk)
    do_write(offset, fds, :binary.copy(<<0>>, chunk))
    zero_range(offset + chunk, remaining - chunk, fds)
  end
end

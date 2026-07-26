defmodule FileHandleLazyTest do
  use ExUnit.Case, async: false

  alias Torrent.FileHandle
  alias Torrent.FileHandle.Piece
  alias Torrent.{Model, PiecesStatistic}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  @piece_len 16

  # Builds a small single-file torrent on disk (optionally corrupting the disk
  # bytes for chosen pieces) and starts the Model + PiecesStatistic + FileHandle
  # stack against a temp dir. Returns the context the tests need.
  defp start_stack(opts \\ []) do
    content = Keyword.get(opts, :content, :crypto.strong_rand_bytes(58))
    write_to_disk? = Keyword.get(opts, :write_to_disk?, false)
    corrupt_indices = Keyword.get(opts, :corrupt, [])

    total = byte_size(content)
    last_index = div(total - 1, @piece_len)
    last_piece_length = total - last_index * @piece_len

    this_len = fn index -> if index == last_index, do: last_piece_length, else: @piece_len end

    pieces = build_piece_hashes(content, last_index, this_len)
    hash = :crypto.strong_rand_bytes(20)
    tmp = Path.join(System.tmp_dir!(), "et_fh_#{Base.encode16(hash)}")
    File.mkdir_p!(tmp)

    if write_to_disk? do
      disk = build_disk_bytes(content, last_index, this_len, corrupt_indices)
      File.write!(Path.join(tmp, "data.bin"), disk)
    end

    torrent = build_lazy_test_torrent(hash, tmp, total, last_index, last_piece_length, pieces)
    start_model_stack(torrent, hash, tmp, content, last_index)
  end

  defp build_piece_hashes(content, last_index, this_len) do
    for index <- 0..last_index, into: <<>> do
      :crypto.hash(:sha, binary_part(content, index * @piece_len, this_len.(index)))
    end
  end

  defp build_disk_bytes(content, last_index, this_len, corrupt_indices) do
    for index <- 0..last_index, into: <<>> do
      clean = binary_part(content, index * @piece_len, this_len.(index))
      maybe_corrupt_piece(index, clean, corrupt_indices)
    end
  end

  defp maybe_corrupt_piece(index, clean, corrupt_indices) do
    if index in corrupt_indices do
      <<first, rest::binary>> = clean
      <<Bitwise.bxor(first, 0xFF), rest::binary>>
    else
      clean
    end
  end

  defp build_lazy_test_torrent(hash, tmp, total, last_index, last_piece_length, pieces) do
    %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => "data.bin",
          "length" => total,
          "piece length" => @piece_len,
          "pieces" => pieces
        }
      },
      left: total,
      last_index: last_index,
      last_piece_length: last_piece_length,
      download_dir: tmp
    }
  end

  defp start_model_stack(torrent, hash, tmp, content, last_index) do
    {:ok, model} = Model.start_link(torrent)
    :ok = PiecesStatistic.init(torrent)
    {:ok, fh} = FileHandle.start_link(hash)

    on_exit(fn ->
      try do
        TestSupport.Sync.safe_stop(fh, 5_000)
      catch
        :exit, _ -> :ok
      end

      try do
        TestSupport.Sync.safe_stop(model, 5_000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp)
    end)

    %{hash: hash, content: content, last_index: last_index, tmp: tmp}
  end

  defp piece_pid(hash, index) do
    case Registry.lookup(Registry, {Piece.key(hash, index), Piece}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp active_pieces(hash) do
    DynamicSupervisor.count_children(FileHandle.piece_supervisor(hash)).active
  end

  test "no piece processes are started eagerly at torrent load" do
    %{hash: hash} = start_stack()
    assert active_pieces(hash) == 0
    assert piece_pid(hash, 0) == nil
  end

  test "a read/write starts the piece on demand and reuses it" do
    %{hash: hash} = start_stack()

    # first access to index 0 starts exactly one process
    assert {:ok, _} = FileHandle.read(hash, 0, 0, 4)
    assert active_pieces(hash) == 1
    pid0 = piece_pid(hash, 0)
    assert is_pid(pid0)

    # further access to the same index reuses the same process
    FileHandle.write(hash, 0, 0, "abcd")
    assert {:ok, "abcd"} = FileHandle.read(hash, 0, 0, 4)
    assert piece_pid(hash, 0) == pid0
    assert active_pieces(hash) == 1

    # a different index starts a second process
    assert {:ok, _} = FileHandle.read(hash, 1, 0, 4)
    assert active_pieces(hash) == 2
    assert piece_pid(hash, 1) != pid0
  end

  test "idle termination frees the process and the next access restarts it with data intact" do
    %{hash: hash} = start_stack()

    FileHandle.write(hash, 0, 0, "hello")
    # cast then call to the same piece: FIFO guarantees the write is applied
    assert {:ok, "hello"} = FileHandle.read(hash, 0, 0, 5)

    pid = piece_pid(hash, 0)
    ref = Process.monitor(pid)

    # Deliver the idle signal exactly as the runtime would after @timeout_idle.
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    refute Process.alive?(pid)
    assert active_pieces(hash) == 0

    # next access lazily restarts a NEW process, and the on-disk data survived
    assert {:ok, "hello"} = FileHandle.read(hash, 0, 0, 5)
    pid2 = piece_pid(hash, 0)
    assert is_pid(pid2)
    assert pid2 != pid
    assert active_pieces(hash) == 1
  end

  test "resume verification marks on-disk pieces complete without spawning piece processes" do
    %{hash: hash, last_index: last_index} =
      start_stack(write_to_disk?: true, corrupt: [1])

    # nothing verified yet
    for index <- 0..last_index do
      assert PiecesStatistic.get_status(hash, index) == nil
    end

    # exactly the bounded-task path Resume now drives
    results =
      0..last_index
      |> Task.async_stream(
        fn index -> {index, FileHandle.verify(hash, index, :resume)} end,
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, res} -> res end)
      |> Map.new()

    Model.sync_progress!(hash)

    for index <- 0..last_index do
      if index == 1 do
        # corrupted on disk: reported absent, left un-completed
        refute results[index]
        assert PiecesStatistic.get_status(hash, index) == nil
      else
        assert results[index]
        assert PiecesStatistic.get_status(hash, index) == :complete
      end
    end

    # the whole verification used transient tasks — no Piece GenServers at all
    assert active_pieces(hash) == 0
  end

  test "coalesced writes flush on check? and preserve piece bytes" do
    %{hash: hash, content: content} = start_stack()
    piece0 = binary_part(content, 0, @piece_len)

    # Four sub-block writes stay buffered (well under @flush_threshold)
    for off <- [0, 4, 8, 12] do
      FileHandle.write(hash, 0, off, binary_part(piece0, off, 4))
    end

    # check? must flush the coalesced buffer before hashing
    assert FileHandle.check?(hash, 0)
    assert {:ok, ^piece0} = FileHandle.read(hash, 0, 0, @piece_len)
  end

  test "explicit flush persists buffered subpiece writes" do
    %{hash: hash} = start_stack()
    FileHandle.write(hash, 0, 0, "abcd")
    :ok = FileHandle.flush(hash, 0)
    assert {:ok, "abcd"} = FileHandle.read(hash, 0, 0, 4)
  end

  test "concurrent writes and reads on one piece stay serialized and correct" do
    %{hash: hash, content: content} = start_stack()
    piece0 = binary_part(content, 0, @piece_len)

    writers =
      for off <- [0, 4, 8, 12] do
        Task.async(fn ->
          chunk = binary_part(piece0, off, 4)
          FileHandle.write(hash, 0, off, chunk)
          # cast-then-call to the same piece process: when this call returns the
          # write has been applied (FIFO within this task -> piece process)
          assert {:ok, ^chunk} = FileHandle.read(hash, 0, off, 4)
        end)
      end

    readers =
      for _ <- 1..8 do
        Task.async(fn ->
          Enum.each(1..20, fn _ ->
            assert match?({:ok, _}, FileHandle.read(hash, 0, 0, @piece_len))
          end)
        end)
      end

    Task.await_many(writers ++ readers, 5_000)

    # every concurrent op went through a single process for this piece
    assert active_pieces(hash) == 1
    assert {:ok, ^piece0} = FileHandle.read(hash, 0, 0, @piece_len)
  end
end

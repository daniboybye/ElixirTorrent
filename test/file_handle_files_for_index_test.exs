defmodule FileHandleFilesForIndexTest do
  # Pure list math (no processes, no disk, no sleeps), so it can run async.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Torrent.FileHandle

  # BitTorrent cuts pieces across the CONCATENATION of all files, so a piece
  # may start in the middle of one file and end in the middle of another. A
  # file belongs to a piece iff it overlaps the byte range [begin, begin+len).
  # `all_files` entries are `{exclusive_end_offset, {path, length} | {:gap, n}}`.

  # Build entries from a list of lengths; `{:gap, n}` marks v2 alignment padding.
  defp layout(items) do
    {entries, _} =
      items
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn
        {{:gap, n}, _i}, acc -> {{acc + n, {:gap, n}}, acc + n}
        {n, i}, acc -> {{acc + n, {"f#{i}", n}}, acc + n}
      end)

    entries
  end

  defp total(entries), do: elem(List.last(entries), 0)

  # Independent oracle: entries with positive overlap with [b, b+len), and the
  # offset of `b` inside the first of them.
  defp expected(entries, b, len) do
    {overlapping, _} =
      Enum.map_reduce(entries, 0, fn {e, spec}, start -> {{start, e, spec}, e} end)

    hits = Enum.filter(overlapping, fn {s, e, _} -> s < b + len and e > b end)
    {first_start, _, _} = hd(hits)
    {b - first_start, Enum.map(hits, fn {_, _, spec} -> spec end)}
  end

  # Only the non-empty slices matter to do_read/do_write (zero-length files
  # are skipped), so drop them before comparing.
  defp positive_slices(files), do: Enum.reject(files, fn {_, n} -> n == 0 end)

  # Bytes actually covered when walking the returned list the way
  # Piece.do_read does: skip `offset` bytes, then take until `len` is satisfied.
  defp covered(offset, files, len) do
    {_, remaining} =
      Enum.reduce(files, {offset, len}, fn {_, flen}, {off, rem} ->
        if off >= flen do
          {off - flen, rem}
        else
          {0, rem - min(flen - off, rem)}
        end
      end)

    len - remaining
  end

  defp check(entries, piece_len, index) do
    b = index * piece_len
    len = min(piece_len, total(entries) - b)
    {offset, files} = FileHandle.files_for_index_for_test(index, entries, piece_len, len)
    {exp_offset, exp_files} = expected(entries, b, len)

    assert covered(offset, files, len) == len
    assert offset == exp_offset
    assert positive_slices(files) == positive_slices(exp_files)
    {offset, files}
  end

  describe "file edge exactly around the piece end" do
    # piece 1 = bytes [10, 20). Single boundary at 20-1, 20, 20+1.
    test "edge at begin+length-1: last byte lives in the NEXT file (the bug)" do
      entries = layout([19, 11])
      {offset, files} = FileHandle.files_for_index_for_test(1, entries, 10, 10)
      assert offset == 10
      assert files == [{"f0", 19}, {"f1", 11}]
    end

    test "edge at begin+length: piece ends exactly at a file end" do
      entries = layout([20, 10])
      assert {10, [{"f0", 20}]} = FileHandle.files_for_index_for_test(1, entries, 10, 10)
    end

    test "edge at begin+length+1: the piece stays inside the file" do
      entries = layout([21, 10])
      assert {10, [{"f0", 21}]} = FileHandle.files_for_index_for_test(1, entries, 10, 10)
    end

    test "all three variants cover exactly `length` bytes" do
      for edge <- [19, 20, 21], do: check(layout([edge, 40 - edge]), 10, 1)
    end
  end

  describe "file edge around the piece start" do
    # piece 1 = bytes [10, 20)
    test "edge at begin-1, begin, begin+1" do
      for edge <- [9, 10, 11], do: check(layout([edge, 30 - edge]), 10, 1)
    end

    test "file ends exactly at begin: first file is the next one, offset 0" do
      assert {0, [{"f1", 10}]} =
               FileHandle.files_for_index_for_test(1, layout([10, 10, 10]), 10, 10)
    end
  end

  describe "special entries" do
    test "single-file torrent, last piece shorter than piece_len" do
      entries = layout([25])
      assert {0, [{"f0", 25}]} = FileHandle.files_for_index_for_test(0, entries, 10, 10)
      assert {20, [{"f0", 25}]} = FileHandle.files_for_index_for_test(2, entries, 10, 5)
    end

    test "last piece ends exactly at the end of the whole torrent" do
      entries = layout([7, 13])
      check(entries, 10, 1)
      check(entries, 10, 0)
    end

    test "zero-length files in the middle and at the end do not raise or lose bytes" do
      entries = layout([5, 0, 0, 5, 5, 0, 0])
      for index <- 0..1, do: check(entries, 10, index)
    end

    test "zero-length file exactly at a piece boundary" do
      entries = layout([10, 0, 10, 0])
      for index <- 0..1, do: check(entries, 10, index)
    end

    test "gap entries (v2 alignment padding) are returned as {:gap, n}" do
      entries = layout([6, {:gap, 4}, 8, {:gap, 2}])
      assert {0, [{"f0", 6}, {:gap, 4}]} = FileHandle.files_for_index_for_test(0, entries, 10, 10)
      assert {0, [{"f2", 8}, {:gap, 2}]} = FileHandle.files_for_index_for_test(1, entries, 10, 10)
    end

    test "gap boundary one byte before the piece end" do
      entries = layout([5, {:gap, 4}, 11])
      check(entries, 10, 0)
      check(entries, 10, 1)
    end
  end

  property "random layouts: returned slices cover exactly the piece bytes" do
    item =
      one_of([
        integer(0..30),
        map(integer(1..10), &{:gap, &1})
      ])

    check all(
            items <- list_of(item, min_length: 1, max_length: 12),
            piece_len <- integer(1..16),
            max_runs: 300
          ) do
      entries = layout(items)

      if total(entries) > 0 do
        last = div(total(entries) - 1, piece_len)
        for index <- 0..last, do: check(entries, piece_len, index)
      end
    end
  end
end

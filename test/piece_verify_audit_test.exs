defmodule PieceVerifyAuditTest do
  @moduledoc """
  When a piece fails its SHA-1 although every byte arrived, the log has to say
  WHOSE fault it was.

  Live: three pieces failed with `read_bytes == expected_len`; one blamed nobody,
  two blamed a lone qBittorrent peer. Nothing in the log could tell "that peer sent
  bad bytes" from "good bytes arrived and our write path mangled them". These tests
  pin down the evidence the failure path now collects and the rule that follows
  from it: a peer is blamed only when the disk still holds exactly what it sent and
  it was the sole source.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Torrent.Downloads.Piece
  alias Torrent.Downloads.Piece.State
  alias Torrent.FileHandle

  @block Piece.max_length()
  @blocks 4
  @piece_len @blocks * @block

  setup do
    hash = :crypto.strong_rand_bytes(20)
    data = :crypto.strong_rand_bytes(@piece_len)
    dir = Path.join(System.tmp_dir!(), "piece_audit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    torrent = %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => "audit.bin",
          "piece length" => @piece_len,
          "length" => @piece_len,
          "pieces" => :crypto.hash(:sha, data)
        }
      },
      left: @piece_len,
      last_index: 0,
      last_piece_length: @piece_len,
      download_dir: dir
    }

    {:ok, model} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    files = start_supervised!({FileHandle, hash})

    on_exit(fn ->
      TestSupport.Sync.safe_stop(files, 1_000)
      TestSupport.Sync.safe_stop(model, 1_000)
    end)

    {:ok, hash: hash, data: data, hash_hex: Torrent.hex_encoded_hash(hash)}
  end

  defp block_of(data, n), do: binary_part(data, n * @block, @block)

  defp corrupt(block), do: :binary.copy(<<0xFF>>, byte_size(block))

  defp subpieces, do: for(n <- 0..(@blocks - 1), do: {n * @block, @block})

  defp state(hash, extra \\ []) do
    base = %State{
      State.make({hash, 0})
      | mode: nil,
        requests_are_dealt: fn -> :ok end,
        downloaded: fn -> :ok end
    }

    struct!(base, extra)
  end

  describe "receipt ledger" do
    test "every accepted block records its sender and a CRC of what was written",
         %{hash: hash, data: data} do
      s =
        hash
        |> state()
        |> State.response("peer-a", 0, block_of(data, 0))
        |> State.response("peer-b", @block, block_of(data, 1))

      assert State.received_digests(s) == [
               {0, @block, :erlang.crc32(block_of(data, 0))},
               {@block, @block, :erlang.crc32(block_of(data, 1))}
             ]

      assert State.unaccounted_blocks(s) == @blocks - 2
      assert State.contributors_summary(s) =~ "peer-a"
    end

    test "a reply to a request we already gave up on is counted as late",
         %{hash: hash, data: data} do
      # peer-b holds the live request for block 0; peer-a's reply is the late one
      # (our request to it timed out and the block was re-assigned).
      req = %Piece.Request{peer_id: "peer-b", subpiece: {0, @block}, timer: nil}
      waiting = List.delete(subpieces(), {0, @block})

      s =
        hash
        |> state(waiting: waiting, requests: [req])
        |> State.response("peer-a", 0, block_of(data, 0))

      assert s.late == 1
      assert s.requests == []
      assert State.sole_contributor(s) == "peer-a"
    end

    test "a copy of a finished block is a duplicate and changes nothing in normal mode",
         %{hash: hash, data: data} do
      s =
        hash
        |> state()
        |> State.response("peer-a", 0, block_of(data, 0))

      dup = State.response(s, "peer-b", 0, corrupt(block_of(data, 0)))

      assert dup.duplicates == 1
      assert dup.blocks == s.blocks
      assert dup.contributors == s.contributors
      # Nothing was written for the duplicate: the disk still has the good copy.
      assert {:ok, stored} = FileHandle.read(hash, 0, 0, @block)
      assert stored == block_of(data, 0)
    end
  end

  describe "endgame duplicates" do
    test "a different copy of a finished block replaces it, and the credit follows the disk",
         %{hash: hash, data: data} do
      s =
        hash
        |> state(mode: :endgame)
        |> State.response("peer-a", 0, block_of(data, 0))
        |> State.response("peer-b", 0, corrupt(block_of(data, 0)))

      assert s.overwritten == 1
      assert s.duplicates == 1
      # peer-a no longer owns any byte on disk: blaming it for a failure caused by
      # peer-b's copy would punish the wrong peer.
      assert s.contributors == %{"peer-b" => 1}
      assert State.sole_contributor(s) == "peer-b"
    end

    test "the same bytes twice are a duplicate, not an overwrite", %{hash: hash, data: data} do
      s =
        hash
        |> state(mode: :endgame)
        |> State.response("peer-a", 0, block_of(data, 0))
        |> State.response("peer-b", 0, block_of(data, 0))

      assert s.overwritten == 0
      assert s.duplicates == 1
      assert s.contributors == %{"peer-a" => 1}
    end

    test "a block that is not one of our subpieces cannot clobber its neighbours",
         %{hash: hash, data: data} do
      s =
        hash
        |> state(mode: :endgame)
        |> State.response("peer-a", 0, block_of(data, 0))
        |> State.response("peer-a", @block, block_of(data, 1))

      # Misaligned and oversized replies: in bounds, so the generic bounds check
      # passes, but they would overwrite parts of two other blocks.
      s = State.response(s, "peer-c", 100, binary_part(data, 100, @block))
      s = State.response(s, "peer-c", 0, binary_part(data, 0, 2 * @block))

      assert s.malformed == 2
      assert {:ok, stored} = FileHandle.read(hash, 0, 0, 2 * @block)
      assert stored == binary_part(data, 0, 2 * @block)
    end
  end

  describe "FileHandle.check_audited/3" do
    test "a valid piece verifies", %{hash: hash, data: data} do
      write_all(hash, data)
      digests = digests_of(data)

      assert FileHandle.check_audited(hash, 0, digests) == true
    end

    test "bad bytes that were received intact show no local mismatch",
         %{hash: hash, data: data} do
      bad = corrupt(block_of(data, 2))
      sent = replace_block(data, 2, bad)
      write_all(hash, sent)

      # The ledger holds the CRC of what the peer sent (the bad block); the disk
      # agrees, so the wire/peer is the only place the corruption can have come from.
      assert {false, []} = FileHandle.check_audited(hash, 0, digests_of(sent))
    end

    test "a block that never reached the disk is reported as zeros",
         %{hash: hash, data: data} do
      # Everything except block 1 was written; the ledger claims it was received.
      write_all(hash, replace_block(data, 1, :binary.copy(<<0>>, @block)))

      assert {false, [{@block, @block, :zeros}]} =
               FileHandle.check_audited(hash, 0, digests_of(data))
    end

    test "a block replaced by other bytes is reported as altered", %{hash: hash, data: data} do
      write_all(hash, replace_block(data, 3, corrupt(block_of(data, 3))))

      assert {false, [{mismatch_begin, @block, :altered}]} =
               FileHandle.check_audited(hash, 0, digests_of(data))

      assert mismatch_begin == 3 * @block
    end

    test "a failed audited check still wipes the piece for the retry", %{hash: hash, data: data} do
      write_all(hash, replace_block(data, 0, corrupt(block_of(data, 0))))

      assert {false, _} = FileHandle.check_audited(hash, 0, digests_of(data))
      assert {:ok, stored} = FileHandle.read(hash, 0, 0, @piece_len)
      assert stored == :binary.copy(<<0>>, @piece_len)
    end
  end

  describe "the piece worker's verdict" do
    test "one peer sent bad bytes and the disk matches: that peer is the culprit",
         %{hash: hash, data: data, hash_hex: hash_hex} do
      log =
        run_worker(hash, fn worker ->
          for n <- 0..(@blocks - 1) do
            bytes = if n == 2, do: corrupt(block_of(data, n)), else: block_of(data, n)
            deliver(worker, hash, "peer-a", n, bytes)
          end
        end)

      assert log =~ "hash=#{hash_hex} index=0 verify_failed verdict=received blame=peer-a"
      assert log =~ "contributors=peer-a:4"
      assert log =~ "mismatch=none"
      assert log =~ "hash=#{hash_hex} index=0 corrupt_source peer=peer-a"
    end

    test "several peers supplied the piece: nobody is blamed, but the evidence is logged",
         %{hash: hash, data: data, hash_hex: hash_hex} do
      log =
        run_worker(hash, fn worker ->
          for n <- 0..(@blocks - 1) do
            peer = if n == 2, do: "peer-b", else: "peer-a"
            bytes = if n == 2, do: corrupt(block_of(data, n)), else: block_of(data, n)
            deliver(worker, hash, peer, n, bytes)
          end
        end)

      assert log =~ "hash=#{hash_hex} index=0 verify_failed verdict=received blame=none"
      assert log =~ "contributors=peer-a:3,peer-b:1"
      refute log =~ "hash=#{hash_hex} index=0 corrupt_source"
    end

    test "a block lost on our side is never pinned on the lone peer that sent the piece",
         %{hash: hash, data: data, hash_hex: hash_hex} do
      log =
        run_worker(hash, fn worker ->
          deliver(worker, hash, "peer-a", 0, block_of(data, 0))
          deliver(worker, hash, "peer-a", 1, block_of(data, 1))

          # Simulate the write for block 1 vanishing between accept and verify
          # (a cast to a piece process that was stopping, a misplaced pwrite, ...):
          # the worker has already counted the block, but the disk lost it.
          :ok = FileHandle.flush(hash, 0)
          FileHandle.write(hash, 0, @block, :binary.copy(<<0>>, @block))
          :ok = FileHandle.flush(hash, 0)

          deliver(worker, hash, "peer-a", 2, block_of(data, 2))
          deliver(worker, hash, "peer-a", 3, block_of(data, 3))
        end)

      assert log =~ "hash=#{hash_hex} index=0 verify_failed verdict=local blame=none"
      assert log =~ "mismatch=#{@block}:zeros"
      refute log =~ "hash=#{hash_hex} index=0 corrupt_source"
    end

    test "an intact piece completes without any failure line",
         %{hash: hash, data: data, hash_hex: hash_hex} do
      log =
        run_worker(hash, fn worker ->
          for n <- 0..(@blocks - 1), do: deliver(worker, hash, "peer-a", n, block_of(data, n))
        end)

      refute log =~ "hash=#{hash_hex} index=0 verify_failed"
      assert_received :piece_downloaded
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp write_all(hash, bytes) do
    FileHandle.write(hash, 0, 0, bytes)
    :ok = FileHandle.flush(hash, 0)
  end

  defp digests_of(bytes) do
    for n <- 0..(@blocks - 1) do
      {n * @block, @block, :erlang.crc32(block_of(bytes, n))}
    end
  end

  defp replace_block(bytes, n, replacement) do
    before = binary_part(bytes, 0, n * @block)
    rest_from = (n + 1) * @block
    rest = binary_part(bytes, rest_from, byte_size(bytes) - rest_from)
    before <> replacement <> rest
  end

  # Starts a real piece worker with every block waiting (as after `download/3`),
  # runs `drive`, and returns what it logged until the worker exits.
  defp run_worker(hash, drive) do
    test_pid = self()

    capture_log(fn ->
      worker = start_supervised!({Piece, [hash, 0]}, restart: :temporary)

      :sys.replace_state(worker, fn %State{} = s ->
        %State{
          s
          | mode: nil,
            requests_are_dealt: fn -> :ok end,
            downloaded: fn -> send(test_pid, :piece_downloaded) end
        }
      end)

      ref = Process.monitor(worker)
      drive.(worker)

      receive do
        {:DOWN, ^ref, :process, ^worker, _reason} -> :ok
      end
    end)
  end

  # Cast the block, then make sure the worker has consumed it before moving on so
  # the helper's own disk writes are ordered after the worker's.
  defp deliver(worker, hash, peer, n, bytes) do
    Piece.response(hash, 0, peer, n * @block, bytes)
    _ = :sys.get_state(worker)
    :ok
  catch
    # The worker exits as soon as the last block is verified.
    :exit, _ -> :ok
  end
end

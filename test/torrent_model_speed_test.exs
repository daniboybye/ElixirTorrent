defmodule TorrentModelSpeedTest do
  use ExUnit.Case, async: true

  # The download readout differences `Torrent.ReceivedBytes`, the byte count every
  # Peer.Controller bumps per accepted block, over a 20 s sliding window. It used to
  # difference `downloaded`, which moves only per verified piece, so a slow torrent
  # read 0 while bytes were arriving (PLAN.md #53b). The window's samples live in
  # the caller's process dictionary, so tests drive time by backdating them rather
  # than by sleeping, and each test owns a random info-hash's counter.
  @piece_bytes 1024 * 1024
  @rate_window 20 * 1_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    hash = :crypto.strong_rand_bytes(20)
    on_exit(fn -> Torrent.ReceivedBytes.delete(hash) end)
    {:ok, hash: hash}
  end

  defp torrent(hash, left) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"piece length" => @piece_bytes, "name" => "t"}},
      left: left,
      last_index: 100,
      last_piece_length: @piece_bytes,
      speed: %{download: 0.0, upload: 0}
    }
  end

  defp key(hash), do: {:speed_rate_window, hash}

  # Replaces the stored samples with one taken `age_ms` ago at `total` bytes.
  defp sample_at(hash, age_ms, total) do
    Process.put(key(hash), [{System.monotonic_time(:millisecond) - age_ms, total}])
  end

  test "reports received bytes per millisecond over the window", %{hash: hash} do
    t = torrent(hash, @piece_bytes * 10)
    sample_at(hash, @rate_window, 0)
    # 1.28 MB in 20 s = 64 KB/s, i.e. 64 bytes/ms.
    :ok = Torrent.ReceivedBytes.add(hash, 1_280_000)

    assert_in_delta Torrent.Model.download_rate_for_test(t), 64.0, 1.0
  end

  test "a torrent slower than one piece per window still reads its real rate",
       %{hash: hash} do
    # The #53b case: no piece completed, so `downloaded` did not move and the old
    # readout said 0, while 200 KB arrived over 20 s.
    t = torrent(hash, @piece_bytes * 10)
    sample_at(hash, @rate_window, 0)
    :ok = Torrent.ReceivedBytes.add(hash, 200_000)

    assert_in_delta Torrent.Model.download_rate_for_test(t), 10.0, 0.5
  end

  test "bytes older than the window stop counting", %{hash: hash} do
    t = torrent(hash, @piece_bytes * 10)
    now = System.monotonic_time(:millisecond)
    :ok = Torrent.ReceivedBytes.add(hash, 5_000_000)
    # 5 MB arrived long ago; nothing since, across a full window of samples.
    Process.put(key(hash), [
      {now - 5_000, 5_000_000},
      {now - 25_000, 5_000_000},
      {now - 60_000, 0}
    ])

    assert Torrent.Model.download_rate_for_test(t) == 0.0
    samples = Process.get(key(hash))
    refute Enum.any?(samples, fn {at, _} -> at == now - 60_000 end)
  end

  test "a fresh window reports zero rather than guessing", %{hash: hash} do
    t = torrent(hash, @piece_bytes * 10)
    :ok = Torrent.ReceivedBytes.add(hash, 1_000_000)

    assert Torrent.Model.download_rate_for_test(t) == 0.0
  end

  test "a completed torrent reports zero", %{hash: hash} do
    t = torrent(hash, 0)
    sample_at(hash, @rate_window, 0)
    :ok = Torrent.ReceivedBytes.add(hash, 1_000_000)

    assert Torrent.Model.download_rate_for_test(t) == 0.0
  end
end

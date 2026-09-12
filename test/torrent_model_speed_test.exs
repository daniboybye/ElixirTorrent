defmodule TorrentModelSpeedTest do
  use ExUnit.Case, async: true

  # `downloaded` advances only when a whole piece completes and verifies, so
  # differencing it over the 5 s tick is quantized to piece size and read 0 for most
  # of a slow torrent's life — the UI showed 0 B/s for torrents demonstrably
  # progressing (PLAN.md #53b). `download_rate/1` therefore averages over a window
  # long enough to span several pieces. These tests pin that, and the window is
  # driven by rewinding the stored anchor rather than by sleeping.
  @piece_bytes 1024 * 1024
  @rate_window 60 * 1_000
  @rate_window_max 10 * 60 * 1_000

  defp torrent(downloaded, left, speed) do
    %Torrent{
      hash: :crypto.strong_rand_bytes(20),
      metadata: %{"info" => %{"piece length" => @piece_bytes, "name" => "t"}},
      left: left,
      last_index: 100,
      last_piece_length: @piece_bytes,
      downloaded: downloaded,
      speed: %{download: speed, upload: 0}
    }
  end

  defp key(torrent), do: {:speed_rate_window, torrent.hash}

  # Opens the window and then backdates it, so a full window can be exercised
  # without waiting a minute.
  defp open_window(torrent, age_ms, downloaded_at_start) do
    Torrent.Model.download_rate_for_test(torrent)
    Process.put(key(torrent), {System.monotonic_time(:millisecond) - age_ms, downloaded_at_start})
    torrent
  end

  describe "download_rate/1" do
    test "a matured window reports the average, not a burst" do
      # 3 MiB over a 60 s window is 3 MiB/60 s — the same figure a hand audit gets
      # from summing `left` deltas. The old code reported either 0 or the ~209 KB/s
      # burst of a single piece landing inside one 5 s tick.
      t = torrent(3 * @piece_bytes, @piece_bytes * 10, 0)
      open_window(t, @rate_window, 0)

      rate = Torrent.Model.download_rate_for_test(t)

      assert_in_delta rate, 3 * @piece_bytes / @rate_window, 1.0
    end

    test "a matured window starts a fresh one so the next average is independent" do
      t = torrent(3 * @piece_bytes, @piece_bytes * 10, 0)
      open_window(t, @rate_window, 0)

      Torrent.Model.download_rate_for_test(t)

      expected = 3 * @piece_bytes
      assert {_at, ^expected} = Process.get(key(t))
    end

    test "the readout holds between pieces instead of collapsing to zero" do
      # The defect itself: every tick between two piece completions used to publish
      # exactly 0.0 while bytes were arriving normally.
      t = torrent(@piece_bytes, @piece_bytes * 10, 55.0)
      open_window(t, 20_000, 0)

      assert Torrent.Model.download_rate_for_test(t) > 0
    end

    test "a moving torrent is held unclamped while its window matures" do
      # A piece has landed in this window, so the rate must be held exactly, not
      # pulled down by piece_length/elapsed. Clamping here made a true 100 KB/s read
      # as 11 KB/s once the window had aged 95 s.
      t = torrent(@piece_bytes, @piece_bytes * 10, 100.0)
      open_window(t, 50_000, 0)

      assert Torrent.Model.download_rate_for_test(t) == 100.0
    end

    test "with nothing arriving the rate is clamped by what the silence proves" do
      # No piece at all in the window: were the torrent still running this fast, the
      # first one would already have landed, so the claim is pulled down.
      absurd = @piece_bytes * 1.0
      t = torrent(@piece_bytes, @piece_bytes * 10, absurd)
      open_window(t, 30_000, @piece_bytes)

      rate = Torrent.Model.download_rate_for_test(t)

      assert rate < absurd
      assert_in_delta rate, @piece_bytes / 30_000, @piece_bytes / 30_000 * 0.2
    end

    test "a torrent that completes nothing for the maximum window reports zero" do
      t = torrent(@piece_bytes, @piece_bytes * 10, 55.0)
      open_window(t, @rate_window_max, @piece_bytes)

      assert Torrent.Model.download_rate_for_test(t) == 0.0
    end

    test "a completed torrent reports zero" do
      t = torrent(@piece_bytes * 10, 0, 500.0)

      assert Torrent.Model.download_rate_for_test(t) == 0.0
    end

    test "a fresh window reports zero rather than guessing" do
      t = torrent(0, @piece_bytes * 10, 0)

      assert Torrent.Model.download_rate_for_test(t) == 0.0
    end
  end
end

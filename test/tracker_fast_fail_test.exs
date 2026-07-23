defmodule TrackerFastFailTest do
  use ExUnit.Case, async: true

  test "fast_fail_request_opts caps HTTP and UDP budgets for under-target announces" do
    opts = Tracker.fast_fail_request_opts()

    assert Keyword.fetch!(opts, :http_timeout_ms) == 15_000
    assert Keyword.fetch!(opts, :max_udp_attempts) == 0
  end

  test "request! with fast_fail opts returns Error quickly on unreachable HTTP tracker" do
    hash = :crypto.strong_rand_bytes(20)
    stats = [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()]

    started = System.monotonic_time(:millisecond)

    result =
      Tracker.request!(
        "http://127.0.0.1:1/announce",
        hash,
        stats,
        Tracker.fast_fail_request_opts()
      )

    elapsed = System.monotonic_time(:millisecond) - started

    assert match?(%Tracker.Error{}, result)
    assert elapsed < 5_000
  end
end

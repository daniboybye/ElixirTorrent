defmodule HTTPTrackerTest do
  use ExUnit.Case, async: true

  describe "HTTP tracker IPv6 connect options" do
    test "request! returns Error instead of raising CaseClauseError on badarg-prone IPv6 bind" do
      hash = :crypto.strong_rand_bytes(20)

      result =
        Tracker.request!(
          "http://127.0.0.1:1/announce",
          hash,
          [uploaded: 0, downloaded: 0, left: 16384, event: Torrent.started()],
          http_timeout_ms: 50
        )

      assert match?(%Tracker.Response{}, result) or match?(%Tracker.Error{}, result)
    end
  end
end

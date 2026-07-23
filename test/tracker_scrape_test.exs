defmodule TrackerScrapeTest do
  use ExUnit.Case, async: true

  describe "BEP 48 scrape URL derivation" do
    test "swaps trailing /announce for /scrape" do
      assert {:ok, "http://tracker.example.com:6969/scrape"} =
               Tracker.http_scrape_url("http://tracker.example.com:6969/announce")
    end

    test "preserves suffix after 'announce' (announce.php → scrape.php)" do
      assert {:ok, "http://tracker.example.com/scrape.php"} =
               Tracker.http_scrape_url("http://tracker.example.com/announce.php")
    end

    test "drops the query string on the announce URL" do
      assert {:ok, "http://tracker.example.com/scrape"} =
               Tracker.http_scrape_url("http://tracker.example.com/announce?foo=bar")
    end

    test "returns :not_scrapeable when no announce segment is present" do
      assert :not_scrapeable = Tracker.http_scrape_url("http://tracker.example.com/track/foo")
    end

    test "returns :not_scrapeable when 'announce' is not at end of path" do
      assert :not_scrapeable =
               Tracker.http_scrape_url("http://tracker.example.com/announce/deep")
    end
  end

  describe "Tracker.scrape/2 error surfacing" do
    test "http URL without an /announce path fails cleanly with :not_scrapeable" do
      hash = :crypto.strong_rand_bytes(20)

      assert %Tracker.Error{reason: :not_scrapeable, retry_in: "never"} =
               Tracker.scrape("http://tracker.example.com/opaque", hash)
    end

    test "unknown scheme is not scrapeable" do
      hash = :crypto.strong_rand_bytes(20)
      assert %Tracker.Error{reason: :not_scrapeable} = Tracker.scrape("ftp://x/announce", hash)
    end
  end
end

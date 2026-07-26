defmodule TrackerHTTPDecodeTest do
  use ExUnit.Case, async: true

  alias Tracker.{Error, Response}

  describe "decode_http_response_for_test/1 (BEP 23 compact + dictionary peers)" do
    test "parses compact IPv4 peers and interval fields" do
      peers_bin = <<1, 2, 3, 4, 6881::16, 5, 6, 7, 8, 8080::16>>

      assert %Response{
               interval: 900,
               complete: 10,
               incomplete: 5,
               peers: peers
             } =
               Tracker.decode_http_response_for_test(%{
                 "interval" => 900,
                 "complete" => 10,
                 "incomplete" => 5,
                 "peers" => peers_bin
               })

      assert length(peers) == 2
      assert hd(peers).ip == {1, 2, 3, 4}
      assert hd(peers).port == 6881
    end

    test "merges dictionary peers and peers6 compact entries" do
      v4_dict = [%{"ip" => "203.0.113.1", "port" => 6881, "peer id" => :binary.copy(<<1>>, 20)}]
      v6_bin = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 9999::16>>

      assert %Response{peers: peers} =
               Tracker.decode_http_response_for_test(%{
                 "interval" => 60,
                 "peers" => v4_dict,
                 "peers6" => v6_bin
               })

      assert length(peers) == 2
      assert Enum.any?(peers, fn %Peer{ip: {203, 0, 113, 1}} -> true end)
      assert Enum.any?(peers, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)
    end

    test "ignores a malformed non-list, non-binary peers value" do
      assert %Response{peers: []} =
               Tracker.decode_http_response_for_test(%{"peers" => %{"ip" => "203.0.113.1"}})
    end

    test "cleanly skips an unsupported dictionary peer hostname" do
      assert %Response{peers: []} =
               Tracker.decode_http_response_for_test(%{
                 "peers" => [%{"ip" => "tracker-peer.invalid", "port" => 6881}]
               })
    end

    test "converts BEP 31 retry_in minutes to internal seconds" do
      assert %Error{reason: "unregistered torrent", retry_in: 300} =
               Tracker.decode_http_response_for_test(%{
                 "failure reason" => "unregistered torrent",
                 "retry in" => 5
               })

      assert %Error{retry_in: 300} =
               Tracker.decode_http_response_for_test(%{
                 "failure reason" => "overloaded",
                 "retry in" => "5"
               })

      assert %Error{retry_in: "never"} =
               Tracker.decode_http_response_for_test(%{
                 "failure reason" => "not a tracker",
                 "retry in" => "never"
               })
    end

    test "defaults interval when omitted" do
      assert %Response{interval: interval, peers: []} =
               Tracker.decode_http_response_for_test(%{"peers" => <<>>})

      assert interval == Tracker.default_interval()
    end

    test "keeps a 4-byte BEP 24 external IP from the decoded response" do
      external_ip = <<203, 0, 113, 7>>

      assert %Response{external_ip: ^external_ip} =
               Tracker.decode_http_response_for_test(%{"external ip" => external_ip})
    end

    test "keeps a 16-byte BEP 24 external IP from the decoded response" do
      external_ip = <<0x2001::16, 0xDB8::16, 0::80, 7::16>>

      assert %Response{external_ip: ^external_ip} =
               Tracker.decode_http_response_for_test(%{"external ip" => external_ip})
    end

    test "uses nil when BEP 24 external IP is absent" do
      assert %Response{external_ip: nil} = Tracker.decode_http_response_for_test(%{})
    end

    test "uses nil when BEP 24 external IP has an invalid packed length" do
      assert %Response{external_ip: nil} =
               Tracker.decode_http_response_for_test(%{"external ip" => <<1, 2, 3, 4, 5>>})
    end
  end

  describe "merge_http_announces_for_test/1 (multi-endpoint announce merge)" do
    test "deduplicates peers and takes min interval / max counts" do
      p1 = %Peer{ip: {1, 2, 3, 4}, port: 6881}
      p2 = %Peer{ip: {5, 6, 7, 8}, port: 6882}

      a = %Response{
        interval: 1_800,
        min_interval: 1_800,
        complete: 3,
        incomplete: 7,
        peers: [p1]
      }

      b = %Response{interval: 900, complete: 10, incomplete: 2, peers: [p1, p2]}

      assert %Response{
               interval: 900,
               min_interval: 1_800,
               complete: 10,
               incomplete: 7,
               peers: merged
             } = Tracker.merge_http_announces_for_test([a, b])

      assert length(merged) == 2
      assert MapSet.new(merged) == MapSet.new([p1, p2])
    end

    test "takes the strictest minimum interval independent of response order" do
      responses = [
        %Response{interval: 1_800, min_interval: nil, complete: 1, incomplete: 1, peers: []},
        %Response{interval: 900, min_interval: 120, complete: 1, incomplete: 1, peers: []},
        %Response{
          interval: 1_200,
          min_interval: 1_800,
          complete: 1,
          incomplete: 1,
          peers: []
        }
      ]

      assert %Response{interval: 900, min_interval: 1_800} =
               Tracker.merge_http_announces_for_test(responses)

      assert %Response{interval: 900, min_interval: 1_800} =
               Tracker.merge_http_announces_for_test(Enum.reverse(responses))
    end

    test "keeps nil minimum interval when no response declares a floor" do
      a = %Response{interval: 1_800, complete: 1, incomplete: 1, peers: []}
      b = %Response{interval: 900, complete: 1, incomplete: 1, peers: []}

      assert %Response{interval: 900, min_interval: nil} =
               Tracker.merge_http_announces_for_test([a, b])
    end

    test "returns first error when every announce failed" do
      e1 = %Error{reason: :timeout}
      e2 = %Error{reason: {:http_status, 503}}

      assert %Error{reason: :timeout} = Tracker.merge_http_announces_for_test([e1, e2])
    end
  end

  describe "decode_http_scrape_body_for_test/2 (BEP 48 scrape dictionary)" do
    test "extracts per-hash scrape stats" do
      hash = :crypto.strong_rand_bytes(20)

      body =
        Bento.encode!(%{
          "files" => %{
            hash => %{"complete" => 5, "incomplete" => 12, "downloaded" => 99}
          }
        })

      assert %{seeders: 5, leechers: 12, completed: 99} =
               Tracker.decode_http_scrape_body_for_test(body, hash)
    end

    test "returns scrape failure reason from body" do
      hash = :crypto.strong_rand_bytes(20)

      body = Bento.encode!(%{"failure reason" => "unsupported scrape"})

      assert %Error{reason: "unsupported scrape"} =
               Tracker.decode_http_scrape_body_for_test(body, hash)
    end

    test "returns :scrape_no_data when hash missing from files map" do
      hash = :crypto.strong_rand_bytes(20)
      other = :crypto.strong_rand_bytes(20)

      body =
        Bento.encode!(%{
          "files" => %{other => %{"complete" => 1, "incomplete" => 2, "downloaded" => 3}}
        })

      assert %Error{reason: :scrape_no_data} =
               Tracker.decode_http_scrape_body_for_test(body, hash)
    end
  end

  describe "loopback HTTP tracker integration" do
    test "request! decodes bencoded announce via local TCP server" do
      hash = :crypto.strong_rand_bytes(20)
      peers_bin = <<127, 0, 0, 1, 6881::16>>

      body =
        Bento.encode!(%{
          "interval" => 120,
          "complete" => 1,
          "incomplete" => 2,
          "peers" => peers_bin
        })

      {port, _pid} = start_http_tracker(fn _req -> {200, body} end)

      stats = [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()]

      assert %Response{interval: 120, peers: [%Peer{} = peer]} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce",
                 hash,
                 stats,
                 http_timeout_ms: 5_000
               )

      assert peer.ip == {127, 0, 0, 1}
    end

    test "request! preserves private tracker authentication before announce parameters" do
      hash = :crypto.strong_rand_bytes(20)
      test_pid = self()
      body = Bento.encode!(%{"interval" => 120, "peers" => <<>>})

      {port, _pid} =
        start_http_tracker(fn request ->
          send(test_pid, {:announce_request, request})
          {200, body}
        end)

      stats = [uploaded: 10, downloaded: 20, left: 30, event: Torrent.started()]

      assert %Response{interval: 120} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce?passkey=private-token&auth=opaque%2Fvalue",
                 hash,
                 stats,
                 http_timeout_ms: 5_000
               )

      assert_receive {:announce_request, request}
      [request_line | _headers] = String.split(request, "\r\n")
      ["GET", request_target, "HTTP/1.1"] = String.split(request_line)

      assert String.starts_with?(
               request_target,
               "/announce?passkey=private-token&auth=opaque%2Fvalue&"
             )

      query = URI.parse(request_target).query
      params = URI.decode_query(query)

      assert params["passkey"] == "private-token"
      assert params["auth"] == "opaque/value"
      assert params["info_hash"] == hash
      assert params["uploaded"] == "10"
      assert params["downloaded"] == "20"
      assert params["left"] == "30"
    end

    test "malformed BEP 24 external IP does not discard peers from the full response" do
      hash = :crypto.strong_rand_bytes(20)
      peers_bin = <<127, 0, 0, 1, 6881::16>>

      body =
        Bento.encode!(%{
          "interval" => 120,
          "external ip" => <<1, 2, 3, 4, 5>>,
          "peers" => peers_bin
        })

      {port, _pid} = start_http_tracker(fn _req -> {200, body} end)
      stats = [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()]

      assert %Response{external_ip: nil, peers: [%Peer{} = peer]} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce",
                 hash,
                 stats,
                 http_timeout_ms: 5_000
               )

      assert peer.ip == {127, 0, 0, 1}
      assert peer.port == 6881
    end

    test "request! parses BEP 31 retry data from a non-2xx response" do
      hash = :crypto.strong_rand_bytes(20)

      body =
        Bento.encode!(%{
          "failure reason" => "Overloaded",
          "retry in" => 5
        })

      {port, _pid} = start_http_tracker(fn _req -> {503, body} end)
      stats = [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()]

      assert %Error{reason: "Overloaded", retry_in: 300} =
               Tracker.request!(
                 "http://127.0.0.1:#{port}/announce",
                 hash,
                 stats,
                 http_timeout_ms: 5_000
               )
    end

    test "extract_js_redirect_for_test and absolute_redirect_for_test" do
      body = ~s(<script>window.location.href="/scrape.php?passkey=x";</script>)
      assert {:ok, "/scrape.php?passkey=x"} = Tracker.extract_js_redirect_for_test(body)

      assert Tracker.absolute_redirect_for_test(
               "http://127.0.0.1:6969/announce?foo=bar",
               "/scrape.php"
             ) == "http://127.0.0.1:6969/scrape.php"
    end

    test "scrape/2 decodes loopback HTTP scrape response" do
      hash = :crypto.strong_rand_bytes(20)

      body =
        Bento.encode!(%{
          "files" => %{
            hash => %{"complete" => 2, "incomplete" => 3, "downloaded" => 4}
          }
        })

      {port, _pid} = start_http_tracker(fn _req -> {200, body} end)

      assert %{seeders: 2, leechers: 3, completed: 4} =
               Tracker.scrape("http://127.0.0.1:#{port}/announce", hash)
    end

    test "scrape/2 preserves a private passkey and appends info_hash with an ampersand" do
      hash = :crypto.strong_rand_bytes(20)
      test_pid = self()

      body =
        Bento.encode!(%{
          "files" => %{
            hash => %{"complete" => 2, "incomplete" => 3, "downloaded" => 4}
          }
        })

      {port, _pid} =
        start_http_tracker(fn request ->
          send(test_pid, {:scrape_request, request})
          {200, body}
        end)

      assert %{seeders: 2, leechers: 3, completed: 4} =
               Tracker.scrape(
                 "http://127.0.0.1:#{port}/announce?passkey=private-token",
                 hash
               )

      expected_query =
        "passkey=private-token&" <> URI.encode_query(%{"info_hash" => hash})

      assert_receive {:scrape_request, request}
      assert request =~ "GET /scrape?#{expected_query} HTTP/1.1"
    end
  end

  describe "resolve_hosts/1 and expected_dns_failure?/1" do
    test "resolve_hosts returns localhost addresses without DNS" do
      assert {:ok, hosts} = Tracker.resolve_hosts("localhost")
      assert Enum.all?(hosts, fn {_ip, family} -> family in [:inet, :inet6] end)
    end

    test "expected_dns_failure? recognizes common dead-tracker reasons" do
      assert Tracker.expected_dns_failure?(:nxdomain)
      assert Tracker.expected_dns_failure?({:nxdomain, ~c"dead.example"})
      refute Tracker.expected_dns_failure?(:bad_response)
    end
  end

  defp start_http_tracker(responder) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn(fn ->
        serve_http(listen, responder)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    {port, pid}
  end

  defp serve_http(listen, responder) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> handle_http_client(socket, responder) end)
        serve_http(listen, responder)

      {:error, _} ->
        :ok
    end
  end

  defp handle_http_client(socket, responder) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, request} ->
        {code, body} = responder.(request)
        status = if code == 200, do: "200 OK", else: "#{code} Error"

        response =
          "HTTP/1.1 #{status}\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

        :gen_tcp.send(socket, response)

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(socket)
  end
end

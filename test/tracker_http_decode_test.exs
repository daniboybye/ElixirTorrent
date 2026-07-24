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

    test "surfaces failure reason and retry_in from tracker body" do
      assert %Error{reason: "unregistered torrent", retry_in: 3600} =
               Tracker.decode_http_response_for_test(%{
                 "failure reason" => "unregistered torrent",
                 "retry in" => 3600
               })
    end

    test "defaults interval when omitted" do
      assert %Response{interval: interval, peers: []} =
               Tracker.decode_http_response_for_test(%{"peers" => <<>>})

      assert interval == Tracker.default_interval()
    end
  end

  describe "merge_http_announces_for_test/1 (multi-endpoint announce merge)" do
    test "deduplicates peers and takes min interval / max counts" do
      p1 = %Peer{ip: {1, 2, 3, 4}, port: 6881}
      p2 = %Peer{ip: {5, 6, 7, 8}, port: 6882}

      a = %Response{interval: 1_800, complete: 3, incomplete: 7, peers: [p1]}
      b = %Response{interval: 900, complete: 10, incomplete: 2, peers: [p1, p2]}

      assert %Response{
               interval: 900,
               complete: 10,
               incomplete: 7,
               peers: merged
             } = Tracker.merge_http_announces_for_test([a, b])

      assert length(merged) == 2
      assert MapSet.new(merged) == MapSet.new([p1, p2])
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
  end

  describe "resolve_hosts/1 and expected_dns_failure?/1" do
    test "resolve_hosts returns localhost addresses without DNS" do
      assert {:ok, hosts} = Tracker.resolve_hosts("localhost")
      assert length(hosts) > 0
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
        spawn(fn ->
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
        end)

        serve_http(listen, responder)

      {:error, _} ->
        :ok
    end
  end
end

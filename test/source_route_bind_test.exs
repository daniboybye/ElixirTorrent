defmodule SourceRouteBindTest do
  @moduledoc """
  BEP 7 makes the tracker announce bind its socket to the address we announce,
  so the tracker records the source it actually sees. A bound source is a
  promise the routing table has to keep: the packet must leave through an
  interface that owns that address.

  Choosing it from a *list* of our addresses (`Acceptor.all_global_ips/0`)
  keeps that promise only on a single-homed host. With a VPN tunnel up, a
  second NIC, or phone tethering, the route to the tracker leaves through one
  interface while the announced address belongs to another. **Windows applies
  the strong host model** (its default since Vista) and refuses the
  `connect`/`sendto` with `WSAEADDRNOTAVAIL` (`:eaddrnotavail`) — *every*
  announce fails and the torrent finds no tracker peers. **macOS/BSD apply the
  weak host model**: the packet goes out carrying a source address the outgoing
  interface does not own, so the same defect is invisible here.

  The source is therefore chosen per destination, from the route:
  `Acceptor.route_source_ip/2` asks the kernel (a UDP `connect` runs the route
  lookup and fixes a local address without sending anything), and
  `Acceptor.select_source_ip/4` decides what to bind. The decision table is
  pure and is exercised against a synthetic interface list, so these tests
  assert the same thing on every machine.
  """
  use ExUnit.Case, async: false

  alias Tracker.{Error, Response}

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  # One physical NIC (en0) with a LAN v4 plus a stable and a temporary global
  # IPv6, and a VPN tunnel (utun3) with its own pair. TEST-NET/documentation
  # ranges throughout: none of these exist on the machine running the suite.
  @lan_v4 {192, 168, 1, 15}
  @lan_v6_stable {0x2001, 0xDB8, 0x1, 0x0, 0, 0, 0, 0x11}
  @lan_v6_temporary {0x2001, 0xDB8, 0x1, 0x0, 0x8A5B, 0x2C, 0x99, 0x4321}
  @link_local_v6 {0xFE80, 0, 0, 0, 0x1010, 0x1EE, 0x10E4, 0x621}
  @vpn_link_local_v6 {0xFE80, 0, 0, 0, 0xCEC1, 0xAA8D, 0x5EE, 0x69E}
  @vpn_v4 {10, 8, 0, 2}
  @vpn_v6 {0x2001, 0xDB8, 0xBEEF, 0, 0, 0, 0, 0x2}
  @second_nic_v4 {192, 168, 44, 8}

  @tracker_v4 {192, 0, 2, 7}
  @tracker_v6 {0x2001, 0xDB8, 0xCAFE, 0, 0, 0, 0, 0x7}
  @foreign_v4 {203, 0, 113, 7}

  @ifaddrs {:ok,
            [
              {~c"lo0",
               [
                 {:flags, [:up, :loopback, :running]},
                 {:addr, @loopback_v4},
                 {:addr, @loopback_v6}
               ]},
              {~c"en0",
               [
                 {:flags, [:up, :broadcast, :running, :multicast]},
                 {:addr, @link_local_v6},
                 {:addr, @lan_v4},
                 {:addr, @lan_v6_stable},
                 {:addr, @lan_v6_temporary}
               ]},
              {~c"en1",
               [
                 {:flags, [:up, :broadcast, :running, :multicast]},
                 {:addr, @second_nic_v4}
               ]},
              {~c"utun3",
               [
                 {:flags, [:up, :pointtopoint, :running]},
                 {:addr, @vpn_link_local_v6},
                 {:addr, @vpn_v4},
                 {:addr, @vpn_v6}
               ]}
            ]}

  describe "Acceptor.select_source_ip/4 — the decision table" do
    test "a loopback destination is never given a source bind" do
      assert Acceptor.select_source_ip(@loopback_v4, @lan_v4, @loopback_v4, @ifaddrs) == nil

      assert Acceptor.select_source_ip(@loopback_v6, @lan_v6_stable, @loopback_v6, @ifaddrs) ==
               nil
    end

    test "no announceable address of that family means no bind" do
      assert Acceptor.select_source_ip(@tracker_v4, nil, @lan_v4, @ifaddrs) == nil
    end

    test "a preference of the wrong family is ignored rather than bound" do
      # An IPv6 source on an IPv4 socket is a badarg at best and a silently
      # wrong bind at worst.
      assert Acceptor.select_source_ip(@tracker_v4, @lan_v6_stable, @lan_v4, @ifaddrs) == nil
      assert Acceptor.select_source_ip(@tracker_v6, @lan_v4, @lan_v6_stable, @ifaddrs) == nil
    end

    test "the single-homed case still binds the announced address (BEP 7)" do
      assert Acceptor.select_source_ip(@tracker_v4, @lan_v4, @lan_v4, @ifaddrs) == @lan_v4

      assert Acceptor.select_source_ip(@tracker_v6, @lan_v6_stable, @lan_v6_stable, @ifaddrs) ==
               @lan_v6_stable
    end

    test "another address of the routing interface keeps our choice (BEP 7)" do
      # RFC 6724 source selection prefers a temporary IPv6 address; we announce
      # the one `all_global_ips/0` picked, and our BEP 42 DHT node id is derived
      # from it. Both addresses live on en0, so the strong host model is
      # satisfied and the bind stays.
      assert Acceptor.select_source_ip(
               @tracker_v6,
               @lan_v6_stable,
               @lan_v6_temporary,
               @ifaddrs
             ) == @lan_v6_stable
    end

    test "a VPN route replaces an address the tunnel interface does not own" do
      # The exact Windows failure: the route to the tracker leaves through
      # utun3, the announced address belongs to en0.
      assert Acceptor.select_source_ip(@tracker_v4, @lan_v4, @vpn_v4, @ifaddrs) == @vpn_v4

      assert Acceptor.select_source_ip(@tracker_v6, @lan_v6_stable, @vpn_v6, @ifaddrs) ==
               @vpn_v6
    end

    test "a second NIC is handled the same way as a tunnel" do
      assert Acceptor.select_source_ip(@tracker_v4, @lan_v4, @second_nic_v4, @ifaddrs) ==
               @second_nic_v4
    end

    test "an unknown route source is bound as-is, not matched against interfaces" do
      # Tethering can add an interface between the route probe and the
      # getifaddrs snapshot. The kernel named the address; trust it.
      fresh = {172, 20, 10, 3}
      assert Acceptor.select_source_ip(@tracker_v4, @lan_v4, fresh, @ifaddrs) == fresh
    end

    test "a route we cannot read keeps the BEP 7 bind" do
      # No route lookup answer (no socket of that family, no route at all). The
      # announce is already in trouble; do not silently drop the bind, and let
      # `Tracker.retry_unbound_source/3` recover if the bind is what fails.
      assert Acceptor.select_source_ip(@tracker_v4, @lan_v4, nil, @ifaddrs) == @lan_v4
    end

    test "a source we would never advertise is dropped instead of bound" do
      # The route leaves through the tunnel, whose only usable source there is a
      # link-local address — not something a tracker can record for us. Bind
      # nothing and let the stack decide.
      assert Acceptor.select_source_ip(
               @tracker_v6,
               @lan_v6_stable,
               @vpn_link_local_v6,
               @ifaddrs
             ) == nil

      assert Acceptor.select_source_ip(@tracker_v4, @lan_v4, @loopback_v4, @ifaddrs) == nil
    end

    test "a link-local source on our own routing interface still binds the global one" do
      # en0 owns both, so the strong host model is satisfied and BEP 7 keeps the
      # global address it wanted to announce.
      assert Acceptor.select_source_ip(@tracker_v6, @lan_v6_stable, @link_local_v6, @ifaddrs) ==
               @lan_v6_stable
    end

    test "a failed getifaddrs falls back to the routed address" do
      assert Acceptor.select_source_ip(@tracker_v4, @lan_v4, @vpn_v4, {:error, :eperm}) ==
               @vpn_v4
    end
  end

  describe "Acceptor.route_source_ip/2 — asking the routing table" do
    test "a loopback destination routes out of the loopback address" do
      assert Acceptor.route_source_ip(@loopback_v4, 6969) == @loopback_v4
      assert Acceptor.route_source_ip(@loopback_v6, 6969) == @loopback_v6
    end

    test "port 0 is normalised, because a datagram socket cannot connect to it" do
      # macOS answers `connect(…, port 0)` with :eaddrnotavail, which would have
      # made the probe report "no route" for every announce URL without a port.
      assert Acceptor.route_source_ip(@loopback_v4, 0) == @loopback_v4
    end

    test "the answer is always an address this host actually owns" do
      case Acceptor.route_source_ip({192, 0, 2, 7}, 6969) do
        nil ->
          # No route off this machine (offline runner) — a valid answer.
          assert true

        source ->
          assert source in host_addresses()
      end
    end

    test "the probe puts no packet on the wire" do
      {:ok, listener} = :gen_udp.open(0, [:binary, {:ip, @loopback_v4}, {:active, true}])
      {:ok, port} = :inet.port(listener)

      try do
        assert Acceptor.route_source_ip(@loopback_v4, port) == @loopback_v4
        refute_receive {:udp, ^listener, _ip, _port, _payload}, 200

        # …and the listener was genuinely able to receive, so the refute above
        # is not vacuous.
        {:ok, sender} = :gen_udp.open(0, [:binary, {:ip, @loopback_v4}, {:active, false}])
        :ok = :gen_udp.send(sender, @loopback_v4, port, "sentinel")
        assert_receive {:udp, ^listener, _ip, _port, "sentinel"}, 2_000
        :gen_udp.close(sender)
      after
        :gen_udp.close(listener)
      end
    end
  end

  describe "Acceptor.announce_source_ip/3 — what the announce binds" do
    test "an unresolved destination keeps the BEP 7 bind" do
      # The HTTP path lets Hackney do its own DNS; with no address there is
      # nothing to route against.
      assert Acceptor.announce_source_ip(nil, 6969, @lan_v4) == @lan_v4
    end

    test "a loopback tracker gets no bind" do
      assert Acceptor.announce_source_ip(@loopback_v4, 6969, @lan_v4) == nil
      assert Acceptor.announce_source_ip(@loopback_v6, 6969, @lan_v6_stable) == nil
    end

    test "nothing to announce means nothing to bind" do
      assert Acceptor.announce_source_ip(@tracker_v4, 6969, nil) == nil
    end

    test "an address no interface owns never reaches the socket" do
      # `@foreign_v4` is TEST-NET-3: binding it fails outright even on macOS.
      route = Acceptor.route_source_ip(@tracker_v4, 6969)
      selected = Acceptor.announce_source_ip(@tracker_v4, 6969, @foreign_v4)

      case route do
        nil ->
          # No route off this machine: the bind survives and the retry in
          # `Tracker` is the remaining net.
          assert selected == @foreign_v4

        source ->
          assert selected == source
          refute selected == @foreign_v4
      end
    end

    test "this host's own primary address is bound unchanged (BEP 7 intact)" do
      case Acceptor.primary_ips().inet do
        nil ->
          assert true

        primary ->
          assert Acceptor.announce_source_ip(primary, 6969, primary) == primary
      end
    end
  end

  describe "Tracker.retry_unbound_source/3 — the last-resort net" do
    test "a rejected bind is retried once with no bind" do
      parent = self()

      result =
        Tracker.retry_unbound_source(%Error{reason: :eaddrnotavail}, @lan_v4, fn ->
          send(parent, :retried_unbound)
          %Response{interval: 1_800, peers: [], complete: 0, incomplete: 0}
        end)

      assert_received :retried_unbound
      assert %Response{} = result
    end

    test "a bind that failed at open is retried too" do
      parent = self()

      Tracker.retry_unbound_source(%Error{reason: {:no_udp_socket, :inet}}, @lan_v4, fn ->
        send(parent, :retried_unbound)
        %Response{interval: 1_800, peers: [], complete: 0, incomplete: 0}
      end)

      assert_received :retried_unbound
    end

    test "an announce that was never bound is not retried" do
      Tracker.retry_unbound_source(%Error{reason: :eaddrnotavail}, nil, fn ->
        send(self(), :must_not_run)
        %Response{interval: 1_800, peers: [], complete: 0, incomplete: 0}
      end)

      refute_received :must_not_run
    end

    test "an ordinary failure is not retried, so a dead tracker is not dialled twice" do
      error = %Error{reason: :timeout}

      assert Tracker.retry_unbound_source(error, @lan_v4, fn ->
               send(self(), :must_not_run)
               %Response{interval: 1_800, peers: [], complete: 0, incomplete: 0}
             end) == error

      refute_received :must_not_run
    end

    test "a successful announce is returned untouched" do
      response = %Response{interval: 1_800, peers: [], complete: 0, incomplete: 0}

      assert Tracker.retry_unbound_source(response, @lan_v4, fn ->
               send(self(), :must_not_run)
               %Response{interval: 60, peers: [], complete: 0, incomplete: 0}
             end) == response

      refute_received :must_not_run
    end

    test "only bind failures count as bind failures" do
      assert Tracker.bind_rejected?(%Error{reason: :eaddrnotavail})
      assert Tracker.bind_rejected?(%Error{reason: {:eaddrnotavail, :connect}})
      assert Tracker.bind_rejected?(%Error{reason: {:no_udp_socket, :inet6}})

      refute Tracker.bind_rejected?(%Error{reason: :timeout})
      refute Tracker.bind_rejected?(%Error{reason: :econnrefused})
      refute Tracker.bind_rejected?(%Error{reason: {:dns, "tracker.invalid", :nxdomain}})

      refute Tracker.bind_rejected?(%Response{
               interval: 1_800,
               peers: [],
               complete: 0,
               incomplete: 0
             })
    end
  end

  describe "HTTP tracker destination resolution" do
    test "the bind is computed against one destination per family, plus the port" do
      assert {dests, 6969, false} =
               Tracker.tracker_dest_ctx_for_test("http://192.0.2.10:6969/announce")

      assert Map.get(dests, :inet) == {192, 0, 2, 10}
      assert Map.get(dests, :inet6) == nil
    end

    test "a URL without a port carries the scheme default into the route probe" do
      assert {_dests, 80, false} = Tracker.tracker_dest_ctx_for_test("http://192.0.2.10/announce")
      assert {_dests, 443, false} = Tracker.tracker_dest_ctx_for_test("https://192.0.2.10/ann")
    end

    test "a loopback-only tracker is flagged, whichever family Hackney picks" do
      # `test_helper.exs` seeds both loopback names, so this holds on every
      # platform rather than depending on the hosts file.
      assert {dests, 6969, true} =
               Tracker.tracker_dest_ctx_for_test("http://localhost:6969/announce")

      assert Map.get(dests, :inet) == @loopback_v4
      assert Map.get(dests, :inet6) == @loopback_v6
    end

    test "an unresolvable tracker keeps both families and no destination" do
      assert {dests, 6969, false} =
               Tracker.tracker_dest_ctx_for_test("http://tracker.invalid.example:6969/announce")

      assert dests == %{}
    end
  end

  describe "a multi-homed announce completes end to end" do
    setup do
      {:ok, _} = Application.ensure_all_started(:elixir_torrent)
      :ok
    end

    test "a UDP announce survives a primary address this machine cannot bind" do
      # Pin the cached "primary" IPv4 to an address no interface owns — the
      # shape a stale getifaddrs snapshot has after a VPN comes up. The
      # announce must still reach a tracker on an address that *is* ours.
      case Acceptor.primary_ips().inet do
        nil ->
          assert true

        primary ->
          {port, server} = start_udp_tracker(primary)
          on_exit(fn -> :gen_udp.close(server) end)

          result =
            with_primary_ipv4(@foreign_v4, fn ->
              Tracker.request!(
                "udp://#{Acceptor.format_ip(primary)}:#{port}/announce",
                :crypto.strong_rand_bytes(20),
                uploaded: 0,
                downloaded: 0,
                left: 1,
                event: Torrent.started()
              )
            end)

          assert %Response{} = result
      end
    end
  end

  ## helpers -----------------------------------------------------------------

  defp host_addresses do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        Enum.flat_map(ifs, fn {_name, props} -> Keyword.get_values(props, :addr) end)

      {:error, _reason} ->
        []
    end
  end

  # Minimal BEP 15 tracker (connect + announce), bound to one address of this
  # host so the announce has a non-loopback destination with a real route.
  defp start_udp_tracker(bind_ip) do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:ip, bind_ip}, {:active, true}])
    {:ok, port} = :inet.port(socket)
    responder = spawn_link(fn -> udp_tracker_loop(socket) end)
    :ok = :gen_udp.controlling_process(socket, responder)
    {port, socket}
  end

  defp udp_tracker_loop(socket) do
    receive do
      {:udp, ^socket, ip, from_port, <<0x41727101980::64, 0::32, transaction::binary-size(4)>>} ->
        :gen_udp.send(socket, ip, from_port, <<0::32, transaction::binary, 7::64>>)
        udp_tracker_loop(socket)

      {:udp, ^socket, ip, from_port, <<7::64, 1::32, transaction::binary-size(4), _rest::binary>>} ->
        :gen_udp.send(
          socket,
          ip,
          from_port,
          <<1::32, transaction::binary, 1_800::32, 0::32, 0::32>>
        )

        udp_tracker_loop(socket)

      {:udp, ^socket, _ip, _port, _other} ->
        udp_tracker_loop(socket)
    end
  end

  defp with_primary_ipv4(ip, fun) do
    key = Acceptor.ip_cache_key()
    previous = :persistent_term.get(key, :missing)

    cache = %{
      inet: ip,
      inet6: nil,
      inet6_all: [],
      multicast_interfaces: %{inet: [], inet6: []}
    }

    cache_pid = Process.whereis(Acceptor.IpCache)
    if cache_pid, do: :sys.suspend(cache_pid)
    :persistent_term.put(key, cache)

    try do
      fun.()
    after
      case previous do
        :missing -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end

      if cache_pid, do: TestSupport.Sync.safe_resume(cache_pid)
    end
  end
end

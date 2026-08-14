defmodule Cycle3LsdStartupCoverageTest do
  @moduledoc """
  Coverage for BEP 14 Local Service Discovery startup on a host with nothing to
  announce on.

  LSD is switched off for the suite (`config/test.exs`) because joining
  `239.192.152.143` / `ff15::efc0:988f` is a real IGMP/MLD membership on a real
  LAN interface. This module turns it back on for its own scope but pins the
  cached multicast-interface list to empty, so the server boots through exactly
  the path it takes on a machine with no multicast-capable interface: it opens
  no socket, logs that it is inert, and still arms its timers.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PeerDiscovery.LSD

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    previous_lsd = Application.get_env(:elixir_torrent, :lsd, [])
    on_exit(fn -> Application.put_env(:elixir_torrent, :lsd, previous_lsd) end)
    Application.put_env(:elixir_torrent, :lsd, enabled: true)

    :ok
  end

  test "boots inert when no interface can carry multicast" do
    with_no_multicast_interfaces()

    log =
      capture_log([level: :info], fn ->
        {:ok, pid} = LSD.start_link([])
        on_exit(fn -> TestSupport.Sync.safe_stop(pid, 500) end)

        state = :sys.get_state(pid)
        assert state.sockets == %{inet: nil, inet6: nil}
        assert state.interfaces == %{inet: [], inet6: []}
        # The cookie still exists: it is what lets us drop the multicast echo of
        # our own announces once an interface does appear.
        assert byte_size(state.cookie) == 12
      end)

    assert log =~ "multicast sockets unavailable"
  end

  test "a refresh that finds the same interfaces keeps the sockets it has" do
    with_no_multicast_interfaces()

    state = %{
      cookie: "keep-me",
      sockets: %{inet: nil, inet6: nil},
      interfaces: %{inet: [], inet6: []},
      announce_queue: []
    }

    assert {:noreply, ^state} = LSD.handle_info(:refresh_interfaces, state)
  end

  test "terminate tolerates a state it did not build" do
    assert :ok = LSD.terminate(:shutdown, :not_a_state)
  end

  test "membership_option/2 targets the BEP 14 groups" do
    assert LSD.membership_option(:inet, {192, 168, 1, 10}) ==
             {:add_membership, {{239, 192, 152, 143}, {192, 168, 1, 10}}}

    assert LSD.membership_option(:inet6, 4) ==
             {:add_membership, {{0xFF15, 0, 0, 0, 0, 0, 0xEFC0, 0x988F}, 4}}
  end

  test "parse_message rejects a datagram that is not BT-SEARCH" do
    assert :error = LSD.parse_message("NOTIFY * HTTP/1.1\r\n\r\n")
  end

  ## helpers -----------------------------------------------------------------

  # Acceptor caches the getifaddrs-derived snapshot in :persistent_term;
  # overriding it is how a test pins what interfaces this host appears to have.
  # This module is async: false, so no concurrent test observes the override.
  defp with_no_multicast_interfaces do
    key = Acceptor.ip_cache_key()
    previous = :persistent_term.get(key, :none)

    on_exit(fn ->
      case previous do
        :none -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end)

    :persistent_term.put(key, %{
      inet: nil,
      inet6: nil,
      inet6_all: [],
      multicast_interfaces: %{inet: [], inet6: []}
    })
  end
end

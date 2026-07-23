defmodule PeerSupervisorShutdownTest do
  use ExUnit.Case, async: true

  test "Peer.start_link uses temporary significant children + auto_shutdown" do
    # Source-level contract: max_restarts:0 + permanent was an intensity hack that
    # made every tcp_closed look like an opaque Controller :shutdown. Prefer
    # OTP auto_shutdown so peer teardown is intentional.
    source = File.read!("lib/elixir_torrent/peer.ex")

    assert source =~ "auto_shutdown: :any_significant"
    assert source =~ "significant: true"
    assert source =~ "restart: :temporary"
    refute source =~ "max_restarts:"
  end
end

defmodule PeerControllerDisconnectLogTest do
  use ExUnit.Case, async: true

  test "quiet_disconnect_reason?/1 silences normal OTP stop paths" do
    assert Peer.Controller.quiet_disconnect_reason?(:normal)
    assert Peer.Controller.quiet_disconnect_reason?(:shutdown)
    assert Peer.Controller.quiet_disconnect_reason?({:shutdown, :swarm_cap})
    assert Peer.Controller.quiet_disconnect_reason?({:shutdown, :protocol_error})
  end

  test "quiet_disconnect_reason?/1 keeps unexpected disconnects audible" do
    refute Peer.Controller.quiet_disconnect_reason?(:timeout)
    refute Peer.Controller.quiet_disconnect_reason?({:error, :closed})
    refute Peer.Controller.quiet_disconnect_reason?(:kill)
  end
end

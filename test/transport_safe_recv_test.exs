defmodule TransportSafeRecvTest do
  use ExUnit.Case, async: true

  alias Peer.Transport

  test "peer_exit_reason maps clean exits to :closed" do
    assert Transport.peer_exit_reason(:normal) == :closed
    assert Transport.peer_exit_reason({:normal, {GenServer, :call, []}}) == :closed
    assert Transport.peer_exit_reason({:shutdown, :tcp_closed}) == :closed
    assert Transport.peer_exit_reason({:noproc, {UTP.Connection, :recv_raw, []}}) == :closed
    assert Transport.peer_exit_reason(:timeout) == :timeout
  end

  test "safe_recv on closed TCP socket returns error without raising" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listen)
    :ok = :gen_tcp.close(server)
    :ok = :gen_tcp.close(listen)

    assert {:error, reason} = Transport.safe_recv(client, 4, 100)
    assert reason in [:closed, :einval]
    :ok = :gen_tcp.close(client)
  end

  test "safe_peername on dead uTP owner returns error without raising" do
    {dead, monitor, release} = TestSupport.Sync.spawn_blocked()
    TestSupport.Sync.release(dead, release)
    TestSupport.Sync.await_down(monitor, dead)

    assert {:error, :closed} = Transport.safe_peername({:utp, dead})
  end

  test "safe_send on dead uTP owner returns error without raising" do
    {dead, monitor, release} = TestSupport.Sync.spawn_blocked()
    TestSupport.Sync.release(dead, release)
    TestSupport.Sync.await_down(monitor, dead)

    assert {:error, :closed} = Transport.safe_send({:utp, dead}, "data")
  end
end

defmodule PeerDiscoveryConnectionIdsTest do
  use ExUnit.Case, async: false

  alias Tracker.UDP

  @protocol_id UDP.protocol_id()
  @connection_id <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88>>

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "get/3 caches BEP 15 connection_id from loopback UDP tracker" do
    {tracker_port, server_pid} = start_connect_server()

    {:ok, socket} =
      :gen_udp.open(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn ->
      :gen_udp.close(socket)
      Process.exit(server_pid, :kill)
    end)

    assert {:ok, @connection_id} =
             PeerDiscovery.connection_id(socket, {127, 0, 0, 1}, tracker_port)

    # Cached — second call should not require another connect round-trip to server.
    assert {:ok, @connection_id} =
             PeerDiscovery.connection_id(socket, {127, 0, 0, 1}, tracker_port)
  end

  test "invalidate/3 drops cached connection_id so next get reconnects" do
    {tracker_port, server_pid} = start_connect_server()

    {:ok, socket} =
      :gen_udp.open(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn ->
      :gen_udp.close(socket)
      Process.exit(server_pid, :kill)
    end)

    assert {:ok, @connection_id} =
             PeerDiscovery.connection_id(socket, {127, 0, 0, 1}, tracker_port)

    :ok = PeerDiscovery.invalidate_connection_id(socket, {127, 0, 0, 1}, tracker_port)

    assert {:ok, @connection_id} =
             PeerDiscovery.connection_id(socket, {127, 0, 0, 1}, tracker_port)
  end

  defp start_connect_server do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} =
          :gen_udp.open(0, [:binary, active: true, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, port} = :inet.port(socket)
        send(parent, {:connect_ready, port})
        connect_loop(socket)
      end)

    receive do
      {:connect_ready, port} -> {port, pid}
    after
      5_000 -> flunk("connect server failed to start")
    end
  end

  defp connect_loop(socket) do
    protocol_id = @protocol_id

    receive do
      {:udp, ^socket, ip, remote_port, data} ->
        <<^protocol_id::binary-size(8), 0::32, tid::binary-size(4)>> = data
        :gen_udp.send(socket, ip, remote_port, <<0::32, tid::binary, @connection_id::binary>>)
        connect_loop(socket)
    after
      60_000 -> :ok
    end
  end
end

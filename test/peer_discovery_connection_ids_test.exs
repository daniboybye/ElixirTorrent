defmodule PeerDiscoveryConnectionIdsTest do
  use ExUnit.Case, async: false

  alias PeerDiscovery.ConnectionIds
  alias PeerDiscovery.ConnectionIds.State
  alias Tracker.Error

  @protocol_id Tracker.UDP.protocol_id()
  @connection_id <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88>>

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "handle_call/3 and handle_info/2 direct GenServer paths" do
    setup do
      {:ok, socket} =
        :gen_udp.open(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, local_port} = :inet.port(socket)
      key = {{127, 0, 0, 1}, 6881, local_port}

      on_exit(fn -> :gen_udp.close(socket) end)

      {:ok, socket: socket, key: key, ip: {127, 0, 0, 1}, port: 6881}
    end

    test "handle_call queues waiters while a connect handshake is in flight", %{
      socket: socket,
      key: key,
      ip: ip,
      port: port
    } do
      first = from()
      state = %State{ids: %{key => [first]}}

      second = from()

      assert {:noreply, queued} =
               ConnectionIds.handle_call([socket, ip, port], second, state)

      assert [^second, ^first] = queued.ids[key]
    end

    test "handle_info request_timeout fails queued waiters with capped retry hint", %{
      key: key
    } do
      waiter = from()
      ref = make_ref()
      timer_ref = make_ref()
      state = %State{ids: %{key => [waiter]}, requests: %{ref => {key, timer_ref}}}

      assert {:noreply, cleared} =
               ConnectionIds.handle_info({:request_timeout, ref}, state)

      refute Map.has_key?(cleared.ids, key)
      refute Map.has_key?(cleared.requests, ref)
      assert_receive {_, %Error{reason: :timeout, retry_in: 60}}
    end

    test "handle_info request_timeout is a no-op for an unknown ref", %{key: key} do
      state = %State{ids: %{key => [from()]}, requests: %{}}

      assert {:noreply, ^state} =
               ConnectionIds.handle_info({:request_timeout, make_ref()}, state)
    end

    test "handle_info request_timeout with missing waiter list clears the request only", %{
      key: key
    } do
      ref = make_ref()
      timer_ref = make_ref()
      state = %State{ids: %{}, requests: %{ref => {key, timer_ref}}}

      assert {:noreply, cleared} =
               ConnectionIds.handle_info({:request_timeout, ref}, state)

      refute Map.has_key?(cleared.requests, ref)
    end

    test "handle_info DOWN with abnormal exit fails waiters", %{key: key} do
      waiter = from()
      ref = make_ref()
      timer_ref = make_ref()
      state = %State{ids: %{key => [waiter]}, requests: %{ref => {key, timer_ref}}}

      assert {:noreply, cleared} =
               ConnectionIds.handle_info({:DOWN, ref, :process, self(), :kill}, state)

      refute Map.has_key?(cleared.ids, key)
      assert_receive {_, :error}
    end

    test "handle_info DOWN with normal exit leaves state unchanged", %{key: key} do
      state = %State{ids: %{key => @connection_id}}

      assert {:noreply, ^state} =
               ConnectionIds.handle_info({:DOWN, make_ref(), :process, self(), :normal}, state)
    end

    test "handle_info task error reply cancels timer and fails waiters", %{key: key} do
      waiter = from()
      ref = make_ref()
      timer_ref = make_ref()
      error = %Error{reason: :timeout, retry_in: 60}

      state = %State{ids: %{key => [waiter]}, requests: %{ref => {key, timer_ref}}}

      assert {:noreply, cleared} =
               ConnectionIds.handle_info({ref, error}, state)

      refute Map.has_key?(cleared.requests, ref)
      assert_receive {_, ^error}
    end

    test "handle_info success reply caches id, notifies waiters, and schedules expiry", %{
      key: key
    } do
      waiter = from()
      ref = make_ref()
      timer_ref = make_ref()
      state = %State{ids: %{key => [waiter]}, requests: %{ref => {key, timer_ref}}}

      assert {:noreply, cached} =
               ConnectionIds.handle_info({ref, @connection_id}, state)

      assert cached.ids[key] == @connection_id
      refute Map.has_key?(cached.requests, ref)
      assert_receive {_, {:ok, @connection_id}}
    end

    test "handle_info success reply ignores unknown task refs", %{key: key} do
      state = %State{ids: %{key => @connection_id}, requests: %{}}

      assert {:noreply, ^state} =
               ConnectionIds.handle_info({make_ref(), @connection_id}, state)
    end

    test "handle_info cache timeout drops a stored connection_id", %{key: key} do
      state = %State{ids: %{key => @connection_id}}

      assert {:noreply, cleared} = ConnectionIds.handle_info({:timeout, key}, state)
      refute Map.has_key?(cleared.ids, key)
    end
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

  defp from, do: {self(), make_ref()}
end

defmodule PeerEndpointsTest do
  use ExUnit.Case, async: false

  @hash :crypto.strong_rand_bytes(20)
  @timeout 2_000

  setup do
    unless Process.whereis(Peer.Endpoints) do
      {:ok, _pid} = start_supervised(Peer.Endpoints)
    end

    :ok
  end

  @tag race_group: :endpoints
  test "registered?/3 tracks live peer processes" do
    peer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    refute Peer.Endpoints.registered?(@hash, {9, 9, 9, 9}, 6881)

    :ok = Peer.Endpoints.register(@hash, {9, 9, 9, 9}, 6881, peer)
    assert Peer.Endpoints.registered?(@hash, {9, 9, 9, 9}, 6881)

    ref = Process.monitor(peer)
    Process.exit(peer, :kill)
    TestSupport.Sync.await_down(ref, peer, @timeout)

    refute Peer.Endpoints.registered?(@hash, {9, 9, 9, 9}, 6881)
  end

  @tag race_group: :endpoints
  test "a queued replacement survives the stale DOWN from the old peer" do
    endpoint = {{9, 9, 9, 8}, 6882}
    {old_peer, old_monitor, _old_release} = TestSupport.Sync.spawn_blocked()
    {new_peer, new_monitor, new_release} = TestSupport.Sync.spawn_blocked()

    assert :ok = Peer.Endpoints.register(@hash, elem(endpoint, 0), elem(endpoint, 1), old_peer)

    parent = self()
    register_gate = make_ref()
    endpoints_pid = Process.whereis(Peer.Endpoints)

    register_task =
      TestSupport.Sync.with_suspended(Peer.Endpoints, fn ->
        task =
          Task.async(fn ->
            send(parent, {:replacement_ready, self()})
            receive do: (^register_gate -> :ok)
            Peer.Endpoints.register(@hash, elem(endpoint, 0), elem(endpoint, 1), new_peer)
          end)

        assert_receive {:replacement_ready, task_pid}, @timeout
        assert task.pid == task_pid
        1 = :erlang.trace(task.pid, true, [:send])
        send(task.pid, register_gate)

        assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _, {:register, _, _, _, _}},
                        ^endpoints_pid},
                       @timeout

        _ = :erlang.trace(task.pid, false, [:send])
        Process.exit(old_peer, :kill)
        TestSupport.Sync.await_down(old_monitor, old_peer, @timeout)
        task
      end)

    assert :ok = Task.await(register_task, @timeout)
    TestSupport.Sync.sync(Peer.Endpoints)
    assert Peer.Endpoints.get_pid(@hash, elem(endpoint, 0), elem(endpoint, 1)) == new_peer

    TestSupport.Sync.release(new_peer, new_release)
    TestSupport.Sync.await_down(new_monitor, new_peer, @timeout)
  end

  @tag race_group: :endpoints
  test "a noted disconnect reason replaces the supervisor's bare :shutdown in the log" do
    endpoint = {{9, 9, 9, 7}, 6883}
    {peer, monitor, _release} = TestSupport.Sync.spawn_blocked()

    :ok = Peer.Endpoints.register(@hash, elem(endpoint, 0), elem(endpoint, 1), peer)

    :ok =
      Peer.Endpoints.note_disconnect_reason(
        @hash,
        elem(endpoint, 0),
        elem(endpoint, 1),
        {:shutdown, :no_mutual_interest}
      )

    TestSupport.Sync.sync(Peer.Endpoints)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(peer, :shutdown)
        TestSupport.Sync.await_down(monitor, peer, @timeout)
        TestSupport.Sync.sync(Peer.Endpoints)
      end)

    assert log =~ "no_mutual_interest"
  end

  @tag race_group: :endpoints
  test "the note is dropped when the endpoint is registered again" do
    endpoint = {{9, 9, 9, 6}, 6884}
    {first, first_monitor, _} = TestSupport.Sync.spawn_blocked()
    {second, second_monitor, _} = TestSupport.Sync.spawn_blocked()

    :ok = Peer.Endpoints.register(@hash, elem(endpoint, 0), elem(endpoint, 1), first)

    :ok =
      Peer.Endpoints.note_disconnect_reason(
        @hash,
        elem(endpoint, 0),
        elem(endpoint, 1),
        {:shutdown, :protocol_error}
      )

    # The note describes the connection that just ended, so a fresh connection to
    # the same endpoint must not inherit it.
    Process.exit(first, :kill)
    TestSupport.Sync.await_down(first_monitor, first, @timeout)
    :ok = Peer.Endpoints.register(@hash, elem(endpoint, 0), elem(endpoint, 1), second)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(second, :shutdown)
        TestSupport.Sync.await_down(second_monitor, second, @timeout)
        TestSupport.Sync.sync(Peer.Endpoints)
      end)

    refute log =~ "protocol_error"
    assert log =~ "reason=:shutdown"
  end

  test "list/1 returns registered endpoints" do
    peer_a =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    peer_b =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = Peer.Endpoints.register(@hash, {1, 2, 3, 4}, 6881, peer_a)
    :ok = Peer.Endpoints.register(@hash, {5, 6, 7, 8}, 6882, peer_b)

    endpoints = Peer.Endpoints.list(@hash) |> MapSet.new()
    assert MapSet.equal?(endpoints, MapSet.new([{{1, 2, 3, 4}, 6881}, {{5, 6, 7, 8}, 6882}]))

    Process.exit(peer_a, :kill)
    Process.exit(peer_b, :kill)
  end
end

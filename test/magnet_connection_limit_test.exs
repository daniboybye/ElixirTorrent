defmodule Magnet.Fetcher.ConnectionLimitTest do
  use ExUnit.Case, async: false

  alias Magnet.Fetcher.ConnectionLimit

  @total 32
  @timeout 2_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    # A fresh limiter per test: a leak in one case must not starve the next.
    reset_limiter()
    on_exit(&reset_limiter/0)
    :ok
  end

  test "a caller that timed out while queued is never granted slots" do
    :ok = ConnectionLimit.acquire(@total)
    test_pid = self()

    # A zero timeout gives up right after the request is sent; the caller stays alive.
    quitter =
      spawn(fn ->
        send(test_pid, {:gave_up, catch_exit(ConnectionLimit.acquire(10, 0))})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:gave_up, {:timeout, _call}}, @timeout

    :ok = ConnectionLimit.release(@total)

    assert :ok = ConnectionLimit.acquire(@total, @timeout)
    send(quitter, :stop)
  end

  test "slots held by a killed process are returned" do
    holder = spawn_holder(@total)
    assert_receive {:acquired, ^holder}, @timeout

    kill(holder)

    assert :ok = ConnectionLimit.acquire(@total, @timeout)
  end

  test "a queued caller that dies leaves the queue" do
    :ok = ConnectionLimit.acquire(@total)
    limiter = Process.whereis(ConnectionLimit)
    1 = :erlang.trace(limiter, true, [:receive])

    waiter = spawn_holder(@total)

    assert_receive {:trace, ^limiter, :receive, {:"$gen_call", {^waiter, _tag}, _request}},
                   @timeout

    1 = :erlang.trace(limiter, false, [:receive])
    kill(waiter)

    :ok = ConnectionLimit.release(@total)

    assert :ok = ConnectionLimit.acquire(@total, @timeout)
  end

  test "a queued caller is served once a holder releases" do
    :ok = ConnectionLimit.acquire(@total)
    waiter = spawn_holder(10)

    :ok = ConnectionLimit.release(@total)

    assert_receive {:acquired, ^waiter}, @timeout
    kill(waiter)
  end

  test "releasing slots the caller does not hold frees nothing" do
    holder = spawn_holder(@total)
    assert_receive {:acquired, ^holder}, @timeout

    :ok = ConnectionLimit.release(@total)

    assert {:timeout, _call} = catch_exit(ConnectionLimit.acquire(1, 0))
    kill(holder)
  end

  defp spawn_holder(count) do
    test_pid = self()

    spawn(fn ->
      :ok = ConnectionLimit.acquire(count, :infinity)
      send(test_pid, {:acquired, self()})
      receive do: (:stop -> :ok)
    end)
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @timeout
  end

  defp reset_limiter do
    {:ok, fresh} = ConnectionLimit.init([])
    _ = :sys.replace_state(ConnectionLimit, fn _leaked -> fresh end)
    :ok
  end
end

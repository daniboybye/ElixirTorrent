defmodule TestSupport.Sync do
  @moduledoc false

  import ExUnit.Assertions

  @default_timeout 2_000

  @spec spawn_blocked(pid()) :: {pid(), reference(), reference()}
  def spawn_blocked(owner \\ self()) do
    release = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(owner, {:test_process_ready, self(), release})

        receive do
          ^release -> :ok
        end
      end)

    assert_receive {:test_process_ready, ^pid, ^release}, @default_timeout
    {pid, monitor_ref, release}
  end

  @spec release(pid(), reference()) :: :ok
  def release(pid, release_ref) do
    send(pid, release_ref)
    :ok
  end

  @spec await_down(reference(), pid(), timeout()) :: term()
  def await_down(monitor_ref, pid, timeout \\ @default_timeout) do
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}, timeout
    reason
  end

  @spec sync(GenServer.server()) :: term()
  def sync(server), do: :sys.get_state(server)

  @spec safe_stop(pid(), timeout()) :: :ok
  def safe_stop(pid, timeout \\ @default_timeout) do
    GenServer.stop(pid, :normal, timeout)
  catch
    :exit, _reason -> :ok
  end

  @spec with_suspended(pid(), (-> result)) :: result when result: term()
  def with_suspended(pid, fun) when is_function(fun, 0) do
    :ok = :sys.suspend(pid)

    try do
      fun.()
    after
      safe_resume(pid)
    end
  end

  @spec safe_resume(pid()) :: :ok
  def safe_resume(pid) do
    :sys.resume(pid)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end
end

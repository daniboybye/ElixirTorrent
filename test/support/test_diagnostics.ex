defmodule TestSupport.Diagnostics do
  @moduledoc false

  @process_fields [
    :registered_name,
    :initial_call,
    :current_function,
    :status,
    :message_queue_len,
    :reductions,
    :memory,
    :links,
    :monitors,
    :monitored_by
  ]

  @spec snapshot(pid()) :: map()
  def snapshot(pid \\ self()) do
    %{
      pid: pid,
      process: Process.info(pid, @process_fields),
      run_queue: :erlang.statistics(:run_queue),
      schedulers: System.schedulers_online(),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit)
    }
  end

  @spec top_mailboxes(pos_integer()) :: list()
  def top_mailboxes(limit \\ 10) do
    :recon.proc_count(:message_queue_len, limit)
  end

  @spec with_sys_trace(pid(), (-> result)) :: result when result: term()
  def with_sys_trace(pid, fun) when is_function(fun, 0) do
    :ok = :sys.trace(pid, true)

    try do
      fun.()
    after
      _ = :sys.trace(pid, false)
    end
  end

  @spec with_process_trace(pid(), [:erlang.trace_flag()], (-> result)) :: result
        when result: term()
  def with_process_trace(pid, flags \\ [:receive, :send, :procs], fun)
      when is_function(fun, 0) do
    1 = :erlang.trace(pid, true, flags)

    try do
      fun.()
    after
      _ = :erlang.trace(pid, false, flags)
    end
  end
end

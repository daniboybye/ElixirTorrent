defmodule Tracker.Fanout do
  @moduledoc false
  # BEP 7 multi-homed announce runs one tracker request per (tracker address,
  # local source). They must not wait on each other: a source whose datagrams
  # are dropped upstream (a VPN that does not route the tracker, a second NIC
  # without a default route) can sit on the full BEP 15 ladder or a 5-minute
  # HTTP timeout, and the peers the other sources already have would wait with
  # it. So the jobs run concurrently, bounded, and:
  #
  # - a `:primary` job — the announce the engine made before multi-homing — is
  #   always run to its own end; its timeouts and retries are unchanged;
  # - a `:secondary` job gets `grace_ms` after the first `%Tracker.Response{}`
  #   of the request. Still running then, it is killed; not started yet, it is
  #   skipped. Both come back as `%Tracker.Error{reason: :source_abandoned}`.
  #
  # A job that raises or exits becomes a `{:source_crashed, _}` error for that
  # job alone. Results come back in job order.

  alias Tracker.{Error, Response}

  @type role :: :primary | :secondary
  @type result :: Response.t() | Error.t()

  @default_max_concurrency 4
  @default_grace_ms 15_000

  @spec default_max_concurrency() :: pos_integer()
  def default_max_concurrency, do: @default_max_concurrency

  @spec default_grace_ms() :: non_neg_integer()
  def default_grace_ms, do: @default_grace_ms

  @spec run([{role(), job}], (job -> result()), keyword()) :: [result()] when job: term()
  def run(jobs, fun, opts \\ []) when is_function(fun, 1) do
    state = %{
      fun: fun,
      max: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      pending: Enum.with_index(jobs, fn {role, job}, index -> {index, role, job} end),
      running: %{},
      results: %{},
      deadline: nil
    }

    state
    |> fill()
    |> loop()
    |> Map.fetch!(:results)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp loop(%{running: running, pending: []} = state) when map_size(running) == 0, do: state

  defp loop(state) do
    state
    |> await()
    |> fill()
    |> loop()
  end

  defp await(%{running: running} = state) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        on_reply(state, ref, result)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        on_down(state, ref, reason)
    after
      wait_ms(state) -> abandon_secondaries(state)
    end
  end

  defp on_reply(state, ref, result) do
    Process.demonitor(ref, [:flush])
    finish(state, ref, result)
  end

  defp on_down(state, ref, reason),
    do: finish(state, ref, %Error{reason: {:source_crashed, reason}})

  defp finish(state, ref, result) do
    {{index, _role, _task}, running} = Map.pop(state.running, ref)

    %{state | running: running, results: Map.put(state.results, index, result)}
    |> maybe_start_grace(result)
  end

  defp maybe_start_grace(%{deadline: nil} = state, %Response{}),
    do: %{state | deadline: now_ms() + state.grace_ms}

  defp maybe_start_grace(state, _result), do: state

  defp fill(%{pending: [{index, role, job} | rest]} = state)
       when map_size(state.running) < state.max do
    if role == :secondary and past_deadline?(state) do
      fill(%{state | pending: rest, results: Map.put(state.results, index, abandoned())})
    else
      %Task{ref: ref} = task = Task.async(fn -> safe_run(state.fun, job) end)
      fill(%{state | pending: rest, running: Map.put(state.running, ref, {index, role, task})})
    end
  end

  defp fill(state), do: state

  # No grace window yet, or nothing left that the window applies to: wait for
  # the next result.
  defp wait_ms(%{deadline: nil}), do: :infinity

  defp wait_ms(state) do
    if secondary_left?(state), do: max(state.deadline - now_ms(), 0), else: :infinity
  end

  defp secondary_left?(state) do
    Enum.any?(state.running, &secondary_task?/1) or
      Enum.any?(state.pending, fn {_index, role, _job} -> role == :secondary end)
  end

  defp abandon_secondaries(state) do
    {secondaries, primaries} = Enum.split_with(state.running, &secondary_task?/1)
    {skipped, pending} = Enum.split_with(state.pending, &match?({_index, :secondary, _job}, &1))

    results =
      Enum.reduce(secondaries, state.results, fn {_ref, {index, _role, task}}, acc ->
        Map.put(acc, index, shutdown_result(task))
      end)

    results = Enum.reduce(skipped, results, &Map.put(&2, elem(&1, 0), abandoned()))
    %{state | running: Map.new(primaries), pending: pending, results: results}
  end

  defp secondary_task?({_ref, {_index, role, _task}}), do: role == :secondary

  # A job that finished between the timeout and the kill keeps its answer.
  defp shutdown_result(task) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> abandoned()
    end
  end

  defp past_deadline?(%{deadline: nil}), do: false
  defp past_deadline?(%{deadline: deadline}), do: now_ms() >= deadline

  defp abandoned, do: %Error{reason: :source_abandoned}

  defp safe_run(fun, job) do
    fun.(job)
  rescue
    exception -> %Error{reason: {:source_crashed, Exception.message(exception)}}
  catch
    kind, reason -> %Error{reason: {:source_crashed, {kind, reason}}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

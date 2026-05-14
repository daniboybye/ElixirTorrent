defmodule Peer.UtPex.RecentCache do
  @moduledoc false

  use GenServer

  alias Peer.UtPex.{BEP40, Entry, Filter}

  @table :ut_pex_recent_cache
  @max_entries_per_family 64
  @max_age_ms 30 * 60 * 1_000
  @target_live_per_family 25
  @sweep_ms 60_000

  @type family :: :inet | :inet6

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec record(Torrent.hash(), Peer.UtPex.Entry.t(), non_neg_integer()) :: :ok
  def record(hash, %Entry{} = entry, now_ms) when is_integer(now_ms) do
    GenServer.cast(__MODULE__, {:record, hash, entry, now_ms})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Adds recent disconnected peers when a family's live PEX set has fewer than #{@target_live_per_family}.

  Returns `{augmented_current, drained_endpoints}` — drained endpoints must leave `sent` on the
  next tick so the per-connection diff emits them as dropped.
  """
  @spec supplement(
          Torrent.hash(),
          %{Peer.UtPex.endpoint() => Entry.t()},
          keyword()
        ) :: {%{Peer.UtPex.endpoint() => Entry.t()}, [Peer.UtPex.endpoint()]}
  def supplement(hash, current, opts \\ []) when is_map(current) do
    GenServer.call(__MODULE__, {:supplement, hash, current, opts}, 5_000)
  catch
    :exit, _ -> {current, []}
  end

  @impl GenServer
  def init(_) do
    table = :ets.new(@table, [:set, :protected, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_cast({:record, hash, entry, now_ms}, %{table: table} = state) do
    family = family_for(entry)
    key = {hash, family}

    list =
      case :ets.lookup(table, key) do
        [{^key, entries}] -> entries
        _ -> []
      end

    ep = Entry.endpoint(entry)

    list =
      list
      |> Enum.reject(fn {_, e} -> Entry.endpoint(e) == ep end)
      |> then(&[{now_ms, entry} | &1])
      |> trim_family(now_ms)

    :ets.insert(table, {key, list})
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:supplement, hash, current, opts}, _, %{table: table} = state) do
    clients = Keyword.get(opts, :clients, %{inet: nil, inet6: nil})

    {augmented, drained} =
      Enum.reduce([:inet, :inet6], {current, []}, fn family, acc_drained ->
        supplement_family(table, hash, family, acc_drained, opts, clients)
      end)

    if drained != [] and Keyword.get(opts, :drain?, true) do
      drained_set = MapSet.new(drained)

      Enum.each([:inet, :inet6], fn family ->
        drain_family_table(table, hash, family, drained_set)
      end)
    end

    {:reply, {augmented, drained}, state}
  end

  defp supplement_family(table, hash, family, {acc, drained_acc}, opts, clients) do
    live = live_count(acc, family)
    need = max(@target_live_per_family - live, 0)

    if need == 0 do
      {acc, drained_acc}
    else
      supplement_family_merge(table, hash, family, {acc, drained_acc}, opts, clients, need)
    end
  end

  defp supplement_family_merge(table, hash, family, {acc, drained_acc}, opts, clients, need) do
    self_ep = Keyword.get(opts, :self_ep)
    candidates = fetch_candidates(table, hash, family, acc, self_ep, now_ms(opts))

    picked =
      candidates
      |> order_candidates(Map.get(clients, family), family)
      |> Enum.take(need)

    merged = merge_pex_entries(acc, picked)
    {merged, drained_acc ++ Enum.map(picked, &Entry.endpoint/1)}
  end

  defp merge_pex_entries(acc, picked) do
    Enum.reduce(picked, acc, fn entry, map ->
      Map.put(map, Entry.endpoint(entry), entry)
    end)
  end

  defp drain_family_table(table, hash, family, drained_set) do
    key = {hash, family}

    case :ets.lookup(table, key) do
      [{^key, list}] ->
        list = Enum.reject(list, fn {_, e} -> MapSet.member?(drained_set, Entry.endpoint(e)) end)
        if list == [], do: :ets.delete(table, key), else: :ets.insert(table, {key, list})

      _ ->
        :ok
    end
  end

  @impl GenServer
  def handle_info(:sweep, %{table: table} = state) do
    now = System.monotonic_time(:millisecond)
    sweep_table(table, now)
    schedule_sweep()
    {:noreply, state}
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  @spec trim_family([{non_neg_integer(), Entry.t()}], non_neg_integer()) ::
          [{non_neg_integer(), Entry.t()}]
  defp trim_family(list, now_ms) do
    list
    |> Enum.reject(fn {ts, _} -> now_ms - ts > @max_age_ms end)
    |> Enum.take(@max_entries_per_family)
  end

  @spec fetch_candidates(:ets.table(), Torrent.hash(), family(), map(), term(), non_neg_integer()) ::
          [Entry.t()]
  defp fetch_candidates(table, hash, family, current, self_ep, now_ms) do
    key = {hash, family}

    case :ets.lookup(table, key) do
      [{^key, list}] ->
        list
        |> Enum.reject(fn {ts, entry} ->
          now_ms - ts > @max_age_ms or Map.has_key?(current, Entry.endpoint(entry)) or
            not Filter.advertisable?(hash, Entry.endpoint(entry), self_ep)
        end)
        |> Enum.map(fn {_, entry} -> entry end)

      _ ->
        []
    end
  end

  @spec order_candidates([Entry.t()], term(), family()) :: [Entry.t()]
  defp order_candidates(entries, client, _family) when is_tuple(client) do
    peers = Enum.map(entries, &Entry.endpoint/1)
    ordered = BEP40.sort_peers(client, peers)
    by_ep = Map.new(entries, &{Entry.endpoint(&1), &1})
    Enum.map(ordered, &Map.fetch!(by_ep, &1))
  end

  defp order_candidates(entries, _, _family), do: Enum.sort_by(entries, &Entry.endpoint/1)

  @spec live_count(map(), family()) :: non_neg_integer()
  defp live_count(current, family) do
    current
    |> Map.keys()
    |> Enum.count(fn ip_port -> family_for_ip(elem(ip_port, 0)) == family end)
  end

  @spec family_for(Entry.t()) :: family()
  defp family_for(%Entry{ip: ip}), do: family_for_ip(ip)

  @spec family_for_ip(:inet.ip_address()) :: family()
  defp family_for_ip({_, _, _, _}), do: :inet
  defp family_for_ip({_, _, _, _, _, _, _, _}), do: :inet6

  @spec now_ms(keyword()) :: non_neg_integer()
  defp now_ms(opts) do
    case Keyword.get(opts, :now_ms) do
      value when is_integer(value) -> value
      _ -> System.monotonic_time(:millisecond)
    end
  end

  @spec sweep_table(:ets.table(), non_neg_integer()) :: :ok
  defp sweep_table(table, now_ms) do
    :ets.foldl(
      fn {key, list}, _acc ->
        trimmed = trim_family(list, now_ms)

        if trimmed == [] do
          :ets.delete(table, key)
        else
          :ets.insert(table, {key, trimmed})
        end

        :ok
      end,
      :ok,
      table
    )
  end
end

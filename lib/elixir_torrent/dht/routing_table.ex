defmodule DHT.RoutingTable do
  @moduledoc """
  BEP 5 § Routing Table — k-buckets (k=8) over the 160-bit node id space.

  Buckets cover contiguous id ranges and split when full and our node id falls
  inside the bucket. Nodes are tracked as good, questionable (15 min idle), or
  bad (failed pings). Only good nodes are returned to peers.
  """

  alias DHT.Compact

  @k 8
  @id_bits 160
  @max_id trunc(:math.pow(2, @id_bits))
  @questionable_after_ms 15 * 60 * 1_000
  @bad_after_failures 2
  @max_nodes 400

  @type node_id :: <<_::160>>
  @type status :: :good | :questionable | :bad

  @type entry :: %{
          id: node_id(),
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          status: status(),
          last_seen_ms: non_neg_integer(),
          last_query_ms: non_neg_integer() | nil,
          failed_queries: non_neg_integer()
        }

  @type bucket :: %{
          min: non_neg_integer(),
          max: non_neg_integer(),
          nodes: [entry()],
          last_changed_ms: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          local_id: node_id(),
          buckets: [bucket()]
        }

  defstruct [:local_id, buckets: []]

  @doc "Create an empty routing table rooted at `local_id` (BEP 5 § Routing Table)."
  @spec new(node_id()) :: t()
  def new(local_id) when byte_size(local_id) == 20 do
    now = now_ms()

    %__MODULE__{
      local_id: local_id,
      buckets: [%{min: 0, max: @max_id, nodes: [], last_changed_ms: now}]
    }
  end

  @doc "BEP 5 distance metric: XOR interpreted as unsigned integer (smaller = closer)."
  @spec distance(node_id(), node_id()) :: non_neg_integer()
  def distance(left, right) when byte_size(left) == 20 and byte_size(right) == 20 do
    <<dist::unsigned-big-integer-size(@id_bits)>> = :crypto.exor(left, right)
    dist
  end

  @doc "Insert or refresh a node learned from the network."
  @spec insert(t(), Compact.contact(), keyword()) :: t()
  def insert(%__MODULE__{} = table, %{id: id, ip: ip, port: port}, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())
    status = Keyword.get(opts, :status, :good)
    from_query? = Keyword.get(opts, :from_query, false)

    cond do
      id == table.local_id ->
        table

      node_count(table) >= @max_nodes and find_entry(table, id) == nil and
          not bad_slot_for_id?(table, id) ->
        table

      true ->
        entry = %{
          id: id,
          ip: ip,
          port: port,
          status: status,
          last_seen_ms: now,
          last_query_ms: if(from_query?, do: now, else: nil),
          failed_queries: 0
        }

        insert_into_bucket(table, id_to_int(id), entry, now)
    end
  end

  @doc "Mark a node good after a successful query response (BEP 5 § good nodes)."
  @spec mark_good(t(), node_id(), keyword()) :: t()
  def mark_good(%__MODULE__{} = table, id, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())
    from_query? = Keyword.get(opts, :from_query, false)

    update_node(table, id, fn entry ->
      %{
        entry
        | status: :good,
          last_seen_ms: now,
          last_query_ms: if(from_query?, do: now, else: entry.last_query_ms),
          failed_queries: 0
      }
    end)
    |> touch_changed(id, now)
  end

  @doc "Mark a node questionable when idle for 15 minutes."
  @spec mark_questionable(t(), node_id(), keyword()) :: t()
  def mark_questionable(%__MODULE__{} = table, id, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    update_node(table, id, fn entry ->
      %{entry | status: :questionable, last_seen_ms: now}
    end)
    |> touch_changed(id, now)
  end

  @doc "Mark a node bad after failed ping (BEP 5 § bad nodes)."
  @spec mark_bad(t(), node_id(), keyword()) :: t()
  def mark_bad(%__MODULE__{} = table, id, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    update_node(table, id, fn entry -> %{entry | status: :bad, last_seen_ms: now} end)
    |> touch_changed(id, now)
  end

  @doc "Record a missed query; BEP 5 marks a node bad only after multiple consecutive misses."
  @spec mark_query_failed(t(), node_id(), keyword()) :: t()
  def mark_query_failed(%__MODULE__{} = table, id, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    table =
      update_node(table, id, fn entry ->
        failures = entry.failed_queries + 1
        status = if failures >= @bad_after_failures, do: :bad, else: entry.status
        %{entry | status: status, failed_queries: failures}
      end)

    if entry_status(table, id) == :bad, do: touch_changed(table, id, now), else: table
  end

  @doc "Remove bad nodes from the table."
  @spec purge_bad(t()) :: t()
  def purge_bad(%__MODULE__{buckets: buckets} = table) do
    buckets =
      Enum.map(buckets, fn bucket ->
        %{bucket | nodes: Enum.reject(bucket.nodes, &(&1.status == :bad))}
      end)

    %{table | buckets: buckets}
  end

  @doc "Return up to `count` closest good nodes to `target` (infohash or node id)."
  @spec closest(t(), node_id(), pos_integer()) :: [entry()]
  def closest(%__MODULE__{} = table, target, count) when count > 0 do
    table
    |> all_entries()
    |> Enum.filter(&(&1.status == :good))
    |> Enum.sort_by(&distance(&1.id, target))
    |> Enum.take(count)
  end

  @doc "Return questionable nodes in a bucket range for refresh ping (oldest first)."
  @spec questionable_entries(t()) :: [entry()]
  def questionable_entries(%__MODULE__{} = table) do
    table
    |> all_entries()
    |> Enum.filter(&(&1.status == :questionable))
    |> Enum.sort_by(& &1.last_seen_ms)
  end

  @doc "Buckets stale for 15 minutes should be refreshed (BEP 5 § refresh)."
  @spec stale_buckets(t(), keyword()) :: [bucket()]
  def stale_buckets(%__MODULE__{} = table, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    Enum.filter(table.buckets, fn bucket ->
      case bucket.last_changed_ms do
        nil -> true
        changed -> now - changed >= @questionable_after_ms
      end
    end)
  end

  @doc "Pick a random id inside a bucket range for find_node refresh."
  @spec random_id_in_bucket(bucket()) :: node_id()
  def random_id_in_bucket(%{min: min, max: max}) do
    span = max - min
    offset = if span > 1, do: :rand.uniform(span - 1), else: 0
    int_to_id(min + offset)
  end

  @doc "Total node count across all buckets."
  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{} = table) do
    table.buckets
    |> Enum.map(&length(&1.nodes))
    |> Enum.sum()
  end

  @doc "Convert routing entries to compact contacts."
  @spec to_contacts([entry()]) :: [Compact.contact()]
  def to_contacts(entries) do
    Enum.map(entries, fn %{id: id, ip: ip, port: port} -> %{id: id, ip: ip, port: port} end)
  end

  @doc "Every node entry across all buckets (order unspecified)."
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{buckets: buckets}) do
    buckets |> Enum.flat_map(& &1.nodes)
  end

  @doc "Find a node regardless of health status."
  @spec find_entry(t(), node_id()) :: entry() | nil
  def find_entry(%__MODULE__{} = table, id) do
    Enum.find(entries(table), &(&1.id == id))
  end

  @doc """
  Return the oldest questionable incumbent that must be pinged before `contact`
  may occupy its full-bucket slot.
  """
  @spec replacement_probe(t(), Compact.contact(), keyword()) :: entry() | nil
  def replacement_probe(%__MODULE__{} = table, %{id: id}, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())
    table = age_questionable(table, now)

    if id == table.local_id or find_entry(table, id) != nil do
      nil
    else
      id_int = id_to_int(id)

      table.buckets
      |> Enum.find(&(id_int >= &1.min and id_int < &1.max))
      |> questionable_replacement()
    end
  end

  @spec all_entries(t()) :: [entry()]
  defp all_entries(table), do: entries(table)

  @spec insert_into_bucket(t(), non_neg_integer(), entry(), non_neg_integer()) :: t()
  defp insert_into_bucket(%__MODULE__{} = table, id_int, entry, now) do
    table = age_questionable(table, now)
    local_id = table.local_id
    buckets = table.buckets
    {new_buckets, _} = insert_bucket(buckets, local_id, id_int, entry, now)
    %{table | buckets: new_buckets}
  end

  @spec insert_bucket([bucket()], node_id(), non_neg_integer(), entry(), non_neg_integer()) ::
          {[bucket()], :done}
  defp insert_bucket(buckets, local_id, id_int, entry, now) do
    Enum.map_reduce(buckets, :done, fn bucket, _ ->
      insert_into_matching_bucket(bucket, local_id, id_int, entry, now)
    end)
    |> flatten_buckets()
  end

  @spec insert_into_matching_bucket(
          bucket(),
          node_id(),
          non_neg_integer(),
          entry(),
          non_neg_integer()
        ) ::
          {bucket() | [bucket()], :done}
  defp insert_into_matching_bucket(bucket, local_id, id_int, entry, now) do
    if id_int >= bucket.min and id_int < bucket.max do
      case put_in_bucket(bucket, local_id, id_int, entry, now) do
        {:ok, bucket} -> {bucket, :done}
        {:split, left, right} -> {[left, right], :done}
      end
    else
      {bucket, :done}
    end
  end

  @spec flatten_buckets({term(), :done}) :: {[bucket()], :done}
  defp flatten_buckets({buckets, tag}) do
    {List.flatten(buckets), tag}
  end

  @spec put_in_bucket(bucket(), node_id(), non_neg_integer(), entry(), non_neg_integer()) ::
          {:ok, bucket()} | {:split, bucket(), bucket()}
  defp put_in_bucket(%{nodes: nodes} = bucket, local_id, id_int, entry, now) do
    case Enum.find_index(nodes, &(&1.id == entry.id)) do
      nil ->
        add_new_node(bucket, local_id, id_int, entry, now)

      index ->
        updated =
          List.update_at(nodes, index, fn existing ->
            %{
              existing
              | ip: entry.ip,
                port: entry.port,
                last_seen_ms: max(existing.last_seen_ms, entry.last_seen_ms),
                last_query_ms: entry.last_query_ms || existing.last_query_ms
            }
          end)

        {:ok, touch_bucket(%{bucket | nodes: updated}, now)}
    end
  end

  @spec add_new_node(bucket(), node_id(), non_neg_integer(), entry(), non_neg_integer()) ::
          {:ok, bucket()} | {:split, bucket(), bucket()}
  defp add_new_node(%{nodes: nodes} = bucket, local_id, _id_int, entry, now) do
    cond do
      length(nodes) < @k ->
        {:ok, touch_bucket(%{bucket | nodes: nodes ++ [entry]}, now)}

      all_good?(nodes) and not local_in_range?(local_id, bucket) ->
        {:ok, bucket}

      all_good?(nodes) and local_in_range?(local_id, bucket) and splittable?(bucket) ->
        split_and_insert(bucket, local_id, entry, now)

      true ->
        {:ok, replace_bad_slot(bucket, entry, now)}
    end
  end

  @spec replace_bad_slot(bucket(), entry(), non_neg_integer()) :: bucket()
  defp replace_bad_slot(%{nodes: nodes} = bucket, entry, now) do
    case Enum.find_index(nodes, &(&1.status == :bad)) do
      nil ->
        bucket

      replacement_index ->
        nodes = List.replace_at(nodes, replacement_index, entry)
        touch_bucket(%{bucket | nodes: nodes}, now)
    end
  end

  @spec split_and_insert(bucket(), node_id(), entry(), non_neg_integer()) ::
          {:split, bucket(), bucket()}
  defp split_and_insert(%{min: min, max: max, nodes: nodes} = bucket, local_id, entry, now) do
    mid = div(min + max, 2)

    {left_nodes, right_nodes} =
      Enum.split_with(nodes, fn %{id: id} -> id_to_int(id) < mid end)

    left = %{bucket | min: min, max: mid, nodes: left_nodes, last_changed_ms: now}
    right = %{bucket | min: mid, max: max, nodes: right_nodes, last_changed_ms: now}

    {left, right} = insert_after_split(left, right, local_id, entry, now)
    {:split, left, right}
  end

  @spec insert_after_split(bucket(), bucket(), node_id(), entry(), non_neg_integer()) ::
          {bucket(), bucket()}
  defp insert_after_split(left, right, local_id, entry, now) do
    target = if id_to_int(entry.id) < left.max, do: left, else: right

    case put_in_bucket(target, local_id, id_to_int(entry.id), entry, now) do
      {:ok, updated} ->
        if id_to_int(entry.id) < left.max do
          {updated, right}
        else
          {left, updated}
        end

      {:split, new_left, new_right} ->
        insert_after_split(new_left, new_right, local_id, entry, now)
    end
  end

  @spec splittable?(bucket()) :: boolean()
  defp splittable?(%{min: min, max: max}), do: max - min > 1

  @spec local_in_range?(node_id(), bucket()) :: boolean()
  defp local_in_range?(local_id, %{min: min, max: max}) do
    id_int = id_to_int(local_id)
    id_int >= min and id_int < max
  end

  @spec all_good?([entry()]) :: boolean()
  defp all_good?(nodes), do: Enum.all?(nodes, &(&1.status == :good))

  @spec questionable_replacement(bucket() | nil) :: entry() | nil
  defp questionable_replacement(%{nodes: nodes}) when length(nodes) >= @k do
    if Enum.any?(nodes, &(&1.status == :bad)) do
      nil
    else
      nodes
      |> Enum.filter(&(&1.status == :questionable))
      |> Enum.min_by(& &1.last_seen_ms, fn -> nil end)
    end
  end

  defp questionable_replacement(_), do: nil

  @spec bad_slot_for_id?(t(), node_id()) :: boolean()
  defp bad_slot_for_id?(table, id) do
    id_int = id_to_int(id)

    case Enum.find(table.buckets, &(id_int >= &1.min and id_int < &1.max)) do
      %{nodes: nodes} -> Enum.any?(nodes, &(&1.status == :bad))
      nil -> false
    end
  end

  @spec age_questionable(t(), non_neg_integer()) :: t()
  defp age_questionable(%__MODULE__{buckets: buckets} = table, now) do
    buckets =
      Enum.map(buckets, fn %{nodes: nodes} = bucket ->
        nodes = Enum.map(nodes, &age_entry_if_stale(&1, now))
        %{bucket | nodes: nodes}
      end)

    %{table | buckets: buckets}
  end

  @spec age_entry_if_stale(entry(), non_neg_integer()) :: entry()
  defp age_entry_if_stale(%{status: :good} = entry, now) do
    if now - entry.last_seen_ms >= @questionable_after_ms do
      %{entry | status: :questionable}
    else
      entry
    end
  end

  defp age_entry_if_stale(entry, _now), do: entry

  @spec update_node(t(), node_id(), (entry() -> entry())) :: t()
  defp update_node(%__MODULE__{buckets: buckets} = table, id, fun) do
    buckets =
      Enum.map(buckets, fn bucket ->
        nodes =
          Enum.map(bucket.nodes, fn
            %{id: ^id} = entry -> fun.(entry)
            other -> other
          end)

        %{bucket | nodes: nodes}
      end)

    %{table | buckets: buckets}
  end

  @spec touch_changed(t(), node_id(), non_neg_integer()) :: t()
  defp touch_changed(table, id, now) do
    id_int = id_to_int(id)

    buckets =
      Enum.map(table.buckets, fn bucket ->
        if id_int >= bucket.min and id_int < bucket.max do
          touch_bucket(bucket, now)
        else
          bucket
        end
      end)

    %{table | buckets: buckets}
  end

  @spec touch_bucket(bucket(), non_neg_integer()) :: bucket()
  defp touch_bucket(bucket, now), do: %{bucket | last_changed_ms: now}

  @spec entry_status(t(), node_id()) :: status() | nil
  defp entry_status(table, id) do
    case find_entry(table, id) do
      %{status: status} -> status
      nil -> nil
    end
  end

  @spec id_to_int(node_id()) :: non_neg_integer()
  defp id_to_int(<<n::unsigned-big-integer-size(@id_bits)>>), do: n

  @spec int_to_id(non_neg_integer()) :: node_id()
  defp int_to_id(n), do: <<rem(n, @max_id)::unsigned-big-integer-size(@id_bits)>>

  @spec now_ms() :: non_neg_integer()
  defp now_ms, do: System.monotonic_time(:millisecond)
end

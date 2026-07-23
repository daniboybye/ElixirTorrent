defmodule DHT.Lookup do
  @moduledoc """
  BEP 5 § Peer lookup — iterative get_peers / find_node shortlist logic (pure functions).

  Maintains the alpha=3 closest-node frontier, merges newly discovered nodes,
  and terminates when the shortlist stops improving or peers are found.
  """

  alias DHT.{Compact, RoutingTable}

  @alpha 3
  @k 8

  @type target :: RoutingTable.node_id()
  @type candidate :: RoutingTable.entry() | Compact.contact()
  @type shortlist_entry :: %{id: RoutingTable.node_id(), queried?: boolean()}

  @doc "Build an initial shortlist of up to `@k` closest nodes from the routing table."
  @spec initial_shortlist(RoutingTable.t() | DHT.RoutingTables.t(), target()) :: [
          shortlist_entry()
        ]
  def initial_shortlist(%{v4: _, v6: _} = tables, target) do
    tables
    |> DHT.RoutingTables.closest(target, @k)
    |> Enum.map(&%{id: &1.id, queried?: false})
  end

  def initial_shortlist(table, target) do
    table
    |> RoutingTable.closest(target, @k)
    |> Enum.map(&%{id: &1.id, queried?: false})
  end

  @doc """
  Pick up to `@alpha` unqueried nodes from the shortlist (BEP 5 iterative search).
  """
  @spec next_queries([shortlist_entry()], pos_integer()) ::
          {[shortlist_entry()], [RoutingTable.node_id()]}
  def next_queries(shortlist, alpha \\ @alpha) do
    {pending, _rest} =
      shortlist
      |> Enum.split_with(&(not &1.queried?))

    queries = pending |> Enum.take(alpha) |> Enum.map(& &1.id)
    marked = Enum.map(queries, &%{id: &1, queried?: true})

    {merge_shortlist(shortlist, marked), queries}
  end

  @doc "Merge newly discovered nodes into the shortlist, keeping the `@k` closest."
  @spec merge_nodes([shortlist_entry()], [Compact.contact() | RoutingTable.entry()], target()) ::
          [shortlist_entry()]
  def merge_nodes(shortlist, nodes, target) do
    existing = Map.new(shortlist, &{&1.id, &1})

    nodes
    |> Enum.uniq_by(&node_id/1)
    |> Enum.reduce(existing, fn node, acc ->
      id = node_id(node)

      Map.update(acc, id, %{id: id, queried?: false}, fn existing_entry ->
        %{existing_entry | id: id}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&RoutingTable.distance(&1.id, target))
    |> Enum.take(@k)
  end

  @doc "Whether iterative search has converged (no unqueried nodes remain)."
  @spec converged?([shortlist_entry()]) :: boolean()
  def converged?(shortlist), do: not Enum.any?(shortlist, &(not &1.queried?))

  @doc """
  Merge the current shortlist with the closest routing-table nodes for `target`.

  Preserves `queried?` flags for ids already in the shortlist so iterative search
  does not re-query nodes after bootstrap fills the table (BEP 5 § peer lookup).
  """
  @spec refresh_shortlist(RoutingTable.t() | DHT.RoutingTables.t(), target(), [shortlist_entry()]) ::
          [shortlist_entry()]
  def refresh_shortlist(%{v4: _, v6: _} = tables, target, shortlist) do
    queried_flags = Map.new(shortlist, &{&1.id, &1.queried?})

    tables
    |> initial_shortlist(target)
    |> Enum.map(fn entry ->
      %{entry | queried?: Map.get(queried_flags, entry.id, false)}
    end)
  end

  def refresh_shortlist(table, target, shortlist) do
    queried_flags = Map.new(shortlist, &{&1.id, &1.queried?})

    table
    |> initial_shortlist(target)
    |> Enum.map(fn entry ->
      %{entry | queried?: Map.get(queried_flags, entry.id, false)}
    end)
  end

  @doc "Whether any shortlist entry is closer than all previously queried nodes."
  @spec improved?([shortlist_entry()], [RoutingTable.node_id()], target()) :: boolean()
  def improved?(shortlist, queried, target) do
    case farthest_queried_distance(queried, target) do
      nil ->
        Enum.any?(shortlist, &(not &1.queried?))

      max_dist ->
        Enum.any?(
          shortlist,
          &(not &1.queried? and RoutingTable.distance(&1.id, target) < max_dist)
        )
    end
  end

  @spec merge_shortlist([shortlist_entry()], [shortlist_entry()]) :: [shortlist_entry()]
  defp merge_shortlist(shortlist, updates) do
    updates_by_id = Map.new(updates, &{&1.id, &1})

    Enum.map(shortlist, fn entry ->
      Map.get(updates_by_id, entry.id, entry)
    end)
  end

  @spec node_id(Compact.contact() | RoutingTable.entry()) :: RoutingTable.node_id()
  defp node_id(%{id: id}), do: id

  @spec farthest_queried_distance([RoutingTable.node_id()], target()) :: non_neg_integer() | nil
  defp farthest_queried_distance([], _target), do: nil

  defp farthest_queried_distance(queried, target) do
    queried |> Enum.map(&RoutingTable.distance(&1, target)) |> Enum.max()
  end
end

defmodule DHT.RoutingTables do
  @moduledoc """
  BEP 32 — separate IPv4 and IPv6 DHT routing tables.

  Each family has its own k-bucket structure keyed by XOR distance. Inserts and
  health updates route by `tuple_size(ip)`; iterative lookups merge closest nodes
  from both tables.
  """

  alias DHT.{Compact, RoutingTable}

  @type family :: :v4 | :v6
  @type t :: %{v4: RoutingTable.t(), v6: RoutingTable.t()}

  @doc "Create empty v4 and v6 routing tables for `node_id`."
  @spec new(RoutingTable.node_id()) :: t()
  def new(node_id) when byte_size(node_id) == 20 do
    %{v4: RoutingTable.new(node_id), v6: RoutingTable.new(node_id)}
  end

  @doc "Route a contact to the table matching its IP family."
  @spec family_for(:inet.ip_address()) :: family()
  def family_for({_, _, _, _}), do: :v4
  def family_for({_, _, _, _, _, _, _, _}), do: :v6
  def family_for(_), do: :v4

  @spec table(t(), family()) :: RoutingTable.t()
  def table(tables, family), do: Map.fetch!(tables, family)

  @spec insert(t(), Compact.contact() | RoutingTable.entry(), keyword()) :: t()
  def insert(tables, %{ip: ip} = contact, opts \\ []) do
    family = family_for(ip)
    update_in(tables, [family], &RoutingTable.insert(&1, contact, opts))
  end

  @spec mark_good(t(), RoutingTable.node_id(), keyword()) :: t()
  def mark_good(tables, id, opts \\ []) do
    update_table_with_id(tables, id, &RoutingTable.mark_good(&1, id, opts))
  end

  @spec mark_bad(t(), RoutingTable.node_id(), keyword()) :: t()
  def mark_bad(tables, id, opts \\ []) do
    update_table_with_id(tables, id, &RoutingTable.mark_bad(&1, id, opts))
  end

  @doc "Up to `count` closest good nodes across both tables (for iterative lookup)."
  @spec closest(t(), RoutingTable.node_id(), pos_integer()) :: [RoutingTable.entry()]
  def closest(tables, target, count) when count > 0 do
    (RoutingTable.closest(tables.v4, target, count) ++
       RoutingTable.closest(tables.v6, target, count))
    |> Enum.sort_by(&RoutingTable.distance(&1.id, target))
    |> Enum.take(count)
  end

  @doc "Closest good nodes from one family table only."
  @spec closest_family(t(), family(), RoutingTable.node_id(), pos_integer()) ::
          [RoutingTable.entry()]
  def closest_family(tables, family, target, count) do
    RoutingTable.closest(table(tables, family), target, count)
  end

  @spec node_count(t()) :: non_neg_integer()
  def node_count(tables) do
    RoutingTable.node_count(tables.v4) + RoutingTable.node_count(tables.v6)
  end

  @spec stale_buckets(t(), keyword()) :: [RoutingTable.bucket()]
  def stale_buckets(tables, opts \\ []) do
    RoutingTable.stale_buckets(tables.v4, opts) ++
      RoutingTable.stale_buckets(tables.v6, opts)
  end

  @spec find_entry(t(), RoutingTable.node_id()) :: RoutingTable.entry() | nil
  def find_entry(tables, id) do
    find_entry_in(table(tables, :v4), id) || find_entry_in(table(tables, :v6), id)
  end

  @spec to_contacts([RoutingTable.entry()]) :: [Compact.contact()]
  def to_contacts(entries), do: RoutingTable.to_contacts(entries)

  @spec update_table_with_id(t(), RoutingTable.node_id(), (RoutingTable.t() -> RoutingTable.t())) ::
          t()
  defp update_table_with_id(tables, id, fun) do
    case table_with_id(tables, id) do
      {:ok, family} -> update_in(tables, [family], fun)
      :error -> tables
    end
  end

  @spec table_with_id(t(), RoutingTable.node_id()) :: {:ok, family()} | :error
  defp table_with_id(tables, id) do
    cond do
      find_entry_in(table(tables, :v4), id) != nil -> {:ok, :v4}
      find_entry_in(table(tables, :v6), id) != nil -> {:ok, :v6}
      true -> :error
    end
  end

  @spec find_entry_in(RoutingTable.t(), RoutingTable.node_id()) :: RoutingTable.entry() | nil
  defp find_entry_in(table, id) do
    table
    |> RoutingTable.closest(id, 160)
    |> Enum.find(&(&1.id == id))
  end
end

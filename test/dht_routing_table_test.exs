defmodule DHTRoutingTableTest do
  use ExUnit.Case, async: true

  alias DHT.{Compact, RoutingTable}

  @local_id <<0::160>>
  @now 1_000_000

  defp contact(id_int, ip \\ {10, 0, 0, 1}, port \\ 6881) do
    id = <<id_int::unsigned-big-integer-size(160)>>
    %{id: id, ip: ip, port: port}
  end

  defp entry(id_int, opts \\ []) do
    status = Keyword.get(opts, :status, :good)
    last_seen = Keyword.get(opts, :last_seen_ms, @now)

    contact(id_int)
    |> Map.merge(%{
      status: status,
      last_seen_ms: last_seen,
      last_query_ms: nil
    })
  end

  describe "XOR distance (BEP 5 § distance metric)" do
    test "distance/2 is symmetric and zero for identical ids" do
      id = :crypto.strong_rand_bytes(20)
      assert RoutingTable.distance(id, id) == 0
      other = :crypto.strong_rand_bytes(20)
      assert RoutingTable.distance(id, other) == RoutingTable.distance(other, id)
    end

    test "closest/3 orders nodes by XOR distance to target" do
      table = RoutingTable.new(@local_id)
      target = <<50::unsigned-big-integer-size(160)>>

      table =
        table
        |> RoutingTable.insert(contact(100), now_ms: @now)
        |> RoutingTable.insert(contact(51), now_ms: @now)
        |> RoutingTable.insert(contact(200), now_ms: @now)

      ids = table |> RoutingTable.closest(target, 3) |> Enum.map(& &1.id)
      assert ids == Enum.sort_by(ids, &RoutingTable.distance(&1, target))
    end
  end

  describe "k-bucket insert and split (BEP 5 § Routing Table)" do
    test "insert fills a bucket up to k=8 nodes" do
      table = RoutingTable.new(@local_id)

      table =
        Enum.reduce(1..8, table, fn n, acc ->
          RoutingTable.insert(acc, contact(n), now_ms: @now)
        end)

      assert RoutingTable.node_count(table) == 8
    end

    test "full bucket outside local range discards new good nodes" do
      base = trunc(:math.pow(2, 159))
      local = contact(1).id
      table = RoutingTable.new(local)

      table =
        Enum.reduce(1..8, table, fn n, acc ->
          RoutingTable.insert(acc, contact(base + n), now_ms: @now)
        end)

      table = RoutingTable.insert(table, contact(base + 9), now_ms: @now)
      assert RoutingTable.node_count(table) == 8
    end

    test "full bucket splits when local id is in range" do
      base = trunc(:math.pow(2, 159))
      local = contact(base + 100).id
      table = RoutingTable.new(local)

      table =
        Enum.reduce(1..8, table, fn n, acc ->
          RoutingTable.insert(acc, contact(base + n), now_ms: @now)
        end)

      table = RoutingTable.insert(table, contact(base + 9), now_ms: @now)
      assert length(table.buckets) >= 2
    end

    test "bad node is replaced on insert" do
      local = contact(1).id
      table = RoutingTable.new(local)

      table =
        Enum.reduce(2..8, table, fn n, acc ->
          RoutingTable.insert(acc, contact(n), now_ms: @now)
        end)

      bad = entry(9, status: :bad)
      bucket = hd(table.buckets)
      bucket = %{bucket | nodes: bucket.nodes ++ [bad]}
      table = %{table | buckets: [bucket]}

      table = RoutingTable.insert(table, contact(10), now_ms: @now)
      refute Enum.any?(RoutingTable.closest(table, contact(10).id, 10), &(&1.id == bad.id))
    end
  end

  describe "node health (BEP 5 § good / questionable / bad)" do
    test "nodes become questionable after 15 minutes idle" do
      table =
        RoutingTable.new(@local_id)
        |> RoutingTable.insert(contact(1), now_ms: @now)

      aged =
        RoutingTable.insert(
          table,
          contact(2),
          now_ms: @now + 16 * 60 * 1_000
        )

      assert [%{status: :questionable}] =
               aged
               |> RoutingTable.questionable_entries()
               |> Enum.filter(&(&1.id == contact(1).id))
    end

    test "mark_bad/2 and purge_bad/1 remove failed nodes" do
      id = contact(1).id

      table =
        RoutingTable.new(@local_id)
        |> RoutingTable.insert(contact(1), now_ms: @now)
        |> RoutingTable.mark_bad(id, now_ms: @now)
        |> RoutingTable.purge_bad()

      assert RoutingTable.node_count(table) == 0
    end
  end

  describe "bucket refresh helpers" do
    test "stale_buckets/1 finds buckets unchanged for 15+ minutes" do
      table = RoutingTable.new(@local_id)
      assert [_bucket] = RoutingTable.stale_buckets(table, now_ms: @now + 16 * 60 * 1_000)
    end

    test "random_id_in_bucket/1 stays inside bucket range" do
      bucket = %{min: 10, max: 20, nodes: [], last_changed_ms: @now}
      id = RoutingTable.random_id_in_bucket(bucket)
      int = :binary.decode_unsigned(id)
      assert int >= 10 and int < 20
    end
  end
end

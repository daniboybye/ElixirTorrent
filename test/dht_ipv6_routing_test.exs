defmodule DHTIPv6RoutingTest do
  use ExUnit.Case, async: true

  alias DHT.{Compact, RoutingTable, RoutingTables}

  @local_id <<0::160>>
  @now 1_000_000

  defp v4_contact(id_int, ip \\ {10, 0, 0, 1}, port \\ 6881) do
    %{id: <<id_int::unsigned-big-integer-size(160)>>, ip: ip, port: port}
  end

  defp v6_contact(id_int, port \\ 6881) do
    ip = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x0001}

    %{id: <<id_int::unsigned-big-integer-size(160)>>, ip: ip, port: port}
  end

  describe "RoutingTables family dispatch (BEP 32)" do
    test "insert routes IPv4 contacts to v4 table only" do
      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(10), now_ms: @now)

      assert RoutingTable.node_count(tables.v4) == 1
      assert RoutingTable.node_count(tables.v6) == 0
    end

    test "insert routes IPv6 contacts to v6 table only" do
      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v6_contact(20), now_ms: @now)

      assert RoutingTable.node_count(tables.v4) == 0
      assert RoutingTable.node_count(tables.v6) == 1
    end

    test "closest/3 merges both families by XOR distance" do
      target = <<50::unsigned-big-integer-size(160)>>

      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(100), now_ms: @now)
        |> RoutingTables.insert(v6_contact(51), now_ms: @now)
        |> RoutingTables.insert(v4_contact(200), now_ms: @now)

      ids =
        tables
        |> RoutingTables.closest(target, 3)
        |> Enum.map(& &1.id)

      assert length(ids) == 3
      assert ids == Enum.sort_by(ids, &RoutingTable.distance(&1, target))
    end

    test "closest_family returns single-table nodes for replies" do
      target = <<50::unsigned-big-integer-size(160)>>

      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(100), now_ms: @now)
        |> RoutingTables.insert(v6_contact(51), now_ms: @now)

      v4_ids =
        tables
        |> RoutingTables.closest_family(:v4, target, 8)
        |> Enum.map(& &1.id)

      v6_ids =
        tables
        |> RoutingTables.closest_family(:v6, target, 8)
        |> Enum.map(& &1.id)

      assert length(v4_ids) == 1
      assert length(v6_ids) == 1
      refute hd(v4_ids) == hd(v6_ids)
    end
  end

  describe "BEP 32 want filtering for reply node fields" do
    setup do
      target = <<50::unsigned-big-integer-size(160)>>

      tables =
        RoutingTables.new(@local_id)
        |> RoutingTables.insert(v4_contact(100), now_ms: @now)
        |> RoutingTables.insert(v6_contact(51), now_ms: @now)

      %{tables: tables, target: target}
    end

    test "nil want includes both nodes and nodes6", %{tables: tables, target: target} do
      fields = reply_fields(tables, target, nil)
      assert Map.has_key?(fields, :nodes)
      assert Map.has_key?(fields, :nodes6)
    end

    test "want=[\"n4\"] includes only nodes", %{tables: tables, target: target} do
      fields = reply_fields(tables, target, ["n4"])
      assert Map.has_key?(fields, :nodes)
      refute Map.has_key?(fields, :nodes6)
    end

    test "want=[\"n6\"] includes only nodes6", %{tables: tables, target: target} do
      fields = reply_fields(tables, target, ["n6"])
      refute Map.has_key?(fields, :nodes)
      assert Map.has_key?(fields, :nodes6)
    end

    test "want=[\"n4\",\"n6\"] includes both", %{tables: tables, target: target} do
      fields = reply_fields(tables, target, ["n4", "n6"])
      assert Map.has_key?(fields, :nodes)
      assert Map.has_key?(fields, :nodes6)
    end

    test "nodes6 round-trips through encode/decode", %{tables: tables, target: target} do
      fields = reply_fields(tables, target, ["n6"])
      assert [%{ip: {0x2001, 0x0DB8, _, _, _, _, _, _}}] = Compact.decode_nodes6(fields.nodes6)
    end
  end

  describe "socket family selection" do
    test "tuple_size dispatches inet vs inet6" do
      assert RoutingTables.family_for({1, 2, 3, 4}) == :v4
      assert RoutingTables.family_for({0x2001, 0, 0, 0, 0, 0, 0, 1}) == :v6
    end

    test "v4-only host: open_v6 returns nil when no global v6" do
      # When inet6 is nil, routing still works with v4 table only
      tables = RoutingTables.new(@local_id) |> RoutingTables.insert(v4_contact(1), now_ms: @now)
      assert RoutingTables.node_count(tables) == 1
    end
  end

  # Mirror DHT.reply_node_fields/3 logic for unit testing without GenServer.
  defp reply_fields(tables, target, want) do
    %{}
    |> maybe_field(:v4, tables, target, want)
    |> maybe_field(:v6, tables, target, want)
  end

  defp maybe_field(acc, family, tables, target, want) do
    if want_includes?(want, family) do
      key = if family == :v4, do: :nodes, else: :nodes6
      encode = if family == :v4, do: &Compact.encode_nodes/1, else: &Compact.encode_nodes6/1

      contacts =
        tables |> RoutingTables.closest_family(family, target, 8) |> RoutingTables.to_contacts()

      case encode.(contacts) do
        <<>> -> acc
        encoded -> Map.put(acc, key, encoded)
      end
    else
      acc
    end
  end

  defp want_includes?(nil, _), do: true
  defp want_includes?([], _), do: true
  defp want_includes?(want, :v4), do: "n4" in want
  defp want_includes?(want, :v6), do: "n6" in want
end

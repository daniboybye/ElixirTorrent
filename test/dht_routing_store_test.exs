defmodule DHT.RoutingStoreTest do
  use ExUnit.Case, async: false

  alias DHT.{RoutingStore, RoutingTable, RoutingTables}

  @node_id :binary.copy(<<0xAB>>, 20)

  setup do
    # RoutingStore uses a fixed path; snapshot and restore it around each test.
    path = RoutingStore.path()
    original = File.read(path)
    on_exit(fn -> restore(path, original) end)
    :ok
  end

  defp restore(path, {:ok, body}), do: File.write!(path, body)
  defp restore(path, _), do: File.rm(path)

  defp contact(id_byte, ip, port), do: %{id: :binary.copy(<<id_byte>>, 20), ip: ip, port: port}

  defp tables_with(contacts) do
    Enum.reduce(contacts, RoutingTables.new(@node_id), fn c, acc ->
      RoutingTables.insert(acc, c)
    end)
  end

  test "save then load round-trips v4 and v6 contacts" do
    tables =
      tables_with([
        contact(0x01, {10, 0, 0, 1}, 6881),
        contact(0x02, {172, 16, 0, 2}, 6882),
        contact(0x03, {0xFD00, 0, 0, 0, 0, 0, 0, 1}, 6883)
      ])

    assert :ok = RoutingStore.save(tables)

    loaded = RoutingStore.load(RoutingTables.new(@node_id))

    assert RoutingTable.node_count(loaded.v4) == 2
    assert RoutingTable.node_count(loaded.v6) == 1

    ids =
      (RoutingTable.entries(loaded.v4) ++ RoutingTable.entries(loaded.v6)) |> Enum.map(& &1.id)

    assert :binary.copy(<<0x01>>, 20) in ids
    assert :binary.copy(<<0x03>>, 20) in ids
  end

  test "reloaded contacts are marked :questionable for re-verification" do
    :ok = RoutingStore.save(tables_with([contact(0x09, {10, 0, 0, 9}, 6881)]))

    loaded = RoutingStore.load(RoutingTables.new(@node_id))
    [entry] = RoutingTable.entries(loaded.v4)

    assert entry.status == :questionable
  end

  test "load leaves tables untouched when no snapshot exists" do
    File.rm(RoutingStore.path())
    tables = RoutingTables.new(@node_id)

    assert RoutingStore.load(tables) == tables
  end

  test "corrupt snapshot is ignored, not fatal" do
    File.mkdir_p!(Path.dirname(RoutingStore.path()))
    File.write!(RoutingStore.path(), <<0, 1, 2, 3, "not a term">>)

    tables = RoutingTables.new(@node_id)
    assert RoutingStore.load(tables) == tables
  end

  test "unknown format version is ignored" do
    payload = %{version: 9999, v4: [], v6: []}
    File.mkdir_p!(Path.dirname(RoutingStore.path()))
    File.write!(RoutingStore.path(), :erlang.term_to_binary(payload))

    tables = RoutingTables.new(@node_id)
    assert RoutingStore.load(tables) == tables
  end

  test "invalid contacts in the snapshot are skipped" do
    payload = %{
      version: 1,
      v4: [
        %{id: :binary.copy(<<1>>, 20), ip: {10, 0, 0, 1}, port: 6881},
        %{id: "too-short", ip: {1, 2, 3, 4}, port: 6881},
        %{id: :binary.copy(<<2>>, 20), ip: {1, 2, 3, 4}, port: 0}
      ],
      v6: []
    }

    File.mkdir_p!(Path.dirname(RoutingStore.path()))
    File.write!(RoutingStore.path(), :erlang.term_to_binary(payload))

    loaded = RoutingStore.load(RoutingTables.new(@node_id))
    assert RoutingTable.node_count(loaded.v4) == 1
  end

  test "persisted public contacts with invalid BEP 42 ids are skipped" do
    payload = %{
      version: 1,
      v4: [%{id: :binary.copy(<<1>>, 20), ip: {192, 0, 2, 1}, port: 6881}],
      v6: []
    }

    File.mkdir_p!(Path.dirname(RoutingStore.path()))
    File.write!(RoutingStore.path(), :erlang.term_to_binary(payload))

    loaded = RoutingStore.load(RoutingTables.new(@node_id))
    assert RoutingTable.node_count(loaded.v4) == 0
  end
end

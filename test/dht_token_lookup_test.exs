defmodule DHTTokenTest do
  use ExUnit.Case, async: true

  alias DHT.Token

  @ip {192, 168, 0, 2}
  @now 1_000_000

  test "issue/2 produces 8-byte tokens" do
    store = Token.new(now_ms: @now)
    token = Token.issue(store, @ip)
    assert byte_size(token) == 8
  end

  test "valid?/3 accepts tokens from current secret" do
    store = Token.new(now_ms: @now)
    token = Token.issue(store, @ip)
    assert Token.valid?(store, @ip, token, now_ms: @now)
  end

  test "valid?/3 accepts previous secret within ten minutes (BEP 5 § tokens)" do
    store = Token.new(now_ms: @now)
    token = Token.issue(store, @ip)

    rotated =
      Token.maybe_rotate(store, now_ms: @now + 6 * 60 * 1_000)

    assert Token.valid?(rotated, @ip, token, now_ms: @now + 6 * 60 * 1_000)
  end

  test "valid?/3 rejects tokens after previous secret expires" do
    store = Token.new(now_ms: @now)
    token = Token.issue(store, @ip)

    rotated =
      Token.maybe_rotate(store, now_ms: @now + 6 * 60 * 1_000)

    refute Token.valid?(rotated, @ip, token, now_ms: @now + 11 * 60 * 1_000)
  end

  test "valid?/3 rejects wrong token" do
    store = Token.new(now_ms: @now)
    refute Token.valid?(store, @ip, <<0::64>>, now_ms: @now)
  end
end

defmodule DHTLookupTest do
  use ExUnit.Case, async: true

  alias DHT.{Compact, Lookup, RoutingTable}

  @local <<0::160>>
  @target <<100::160>>

  defp contact(n), do: %{id: <<n::160>>, ip: {10, 0, 0, 1}, port: 6881}

  test "initial_shortlist/2 returns closest nodes by XOR" do
    table =
      RoutingTable.new(@local)
      |> RoutingTable.insert(contact(90), now_ms: 0)
      |> RoutingTable.insert(contact(110), now_ms: 0)
      |> RoutingTable.insert(contact(200), now_ms: 0)

    shortlist = Lookup.initial_shortlist(table, @target)
    assert length(shortlist) == 3
    assert hd(shortlist).id == contact(110).id
  end

  test "next_queries/2 returns alpha unqueried nodes" do
    shortlist = [
      %{id: contact(1).id, queried?: false},
      %{id: contact(2).id, queried?: false},
      %{id: contact(3).id, queried?: false},
      %{id: contact(4).id, queried?: false}
    ]

    {updated, queries} = Lookup.next_queries(shortlist, 3)
    assert length(queries) == 3
    assert Enum.count(updated, & &1.queried?) == 3
    refute Enum.at(updated, 3).queried?
  end

  test "merge_nodes/3 keeps k closest and preserves queried flags" do
    shortlist = [%{id: contact(1).id, queried?: true}]
    merged = Lookup.merge_nodes(shortlist, [contact(50), contact(105)], @target)
    assert length(merged) <= 8
    assert Enum.any?(merged, &(&1.id == contact(105).id))
  end

  test "converged?/1 when every node was queried" do
    shortlist = [%{id: contact(1).id, queried?: true}]
    assert Lookup.converged?(shortlist)
    refute Lookup.converged?([%{id: contact(1).id, queried?: false}])
  end

  test "refresh_shortlist/3 keeps queried flags and adds closer bootstrap nodes" do
    table =
      RoutingTable.new(@local)
      |> RoutingTable.insert(contact(100), now_ms: 0)
      |> RoutingTable.insert(contact(105), now_ms: 0)

    shortlist = [%{id: contact(100).id, queried?: true}]
    refreshed = Lookup.refresh_shortlist(table, @target, shortlist)

    assert Enum.any?(refreshed, &(&1.id == contact(100).id and &1.queried?))
    assert Enum.any?(refreshed, &(&1.id == contact(105).id and not &1.queried?))
  end
end

defmodule DHTCompactHelpersTest do
  use ExUnit.Case, async: true

  alias DHT.Compact

  @node_id <<0xAB::160>>
  @v4 {192, 0, 2, 1}
  @v6 {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
  @port 6881

  describe "BEP 5 compact node info (26 bytes)" do
    test "encode_node/decode_nodes round-trip preserves id, ip, and port" do
      assert {:ok, entry} = encode_node_ok(@node_id, @v4, @port)
      assert byte_size(entry) == Compact.node_info_size()

      assert [%{id: @node_id, ip: @v4, port: @port}] = Compact.decode_nodes(entry)

      nodes = [%{id: @node_id, ip: @v4, port: @port}]
      assert Compact.decode_nodes(Compact.encode_nodes(nodes)) == nodes
    end

    test "encode_nodes skips unsupported IPv6 contacts" do
      mixed = [
        %{id: @node_id, ip: @v4, port: @port},
        %{id: <<1::160>>, ip: @v6, port: @port}
      ]

      bin = Compact.encode_nodes(mixed)
      assert byte_size(bin) == Compact.node_info_size()
      assert Compact.decode_nodes(bin) == [hd(mixed)]
    end

    test "decode_nodes ignores truncated tail bytes" do
      entry = encode_node_ok!(@node_id, @v4, @port)

      assert Compact.decode_nodes(entry <> <<0xFF, 0xFE>>) == [
               %{id: @node_id, ip: @v4, port: @port}
             ]
    end

    test "encode_node rejects invalid id, ip family, and port" do
      assert Compact.encode_node(<<0::128>>, @v4, @port) == {:error, :unsupported_ip}
      assert Compact.encode_node(@node_id, @v6, @port) == {:error, :unsupported_ip}
      assert Compact.encode_node(@node_id, @v4, 0) == {:error, :unsupported_ip}
      assert Compact.encode_node(@node_id, @v4, 70_000) == {:error, :unsupported_ip}
    end
  end

  describe "BEP 23 compact peers (6 bytes)" do
    test "encode_peer/decode_peers round-trip" do
      bin = encode_peer_ok!(@v4, @port)
      assert byte_size(bin) == Compact.peer_info_size()
      assert [%Peer{ip: @v4, port: @port}] = Compact.decode_peers(bin)
    end

    test "decode_peers ignores truncated tail" do
      bin = encode_peer_ok!(@v4, @port)
      assert Compact.decode_peers(bin <> <<0x01>>) == [%Peer{ip: @v4, port: @port}]
    end

    test "encode_peer rejects IPv6 and invalid port" do
      assert Compact.encode_peer(@v6, @port) == {:error, :unsupported_ip}
      assert Compact.encode_peer(@v4, 0) == {:error, :unsupported_ip}
    end
  end

  describe "BEP 32 compact IPv6 node info and peers" do
    test "encode_node6/decode_nodes6 round-trip" do
      bin = encode_node6_ok!(@node_id, @v6, @port)
      assert byte_size(bin) == Compact.node_info6_size()
      assert [%{id: @node_id, ip: @v6, port: @port}] = Compact.decode_nodes6(bin)
    end

    test "encode_nodes6 skips IPv4 contacts" do
      v6_node = %{id: <<2::160>>, ip: @v6, port: 6882}
      mixed = [%{id: @node_id, ip: @v4, port: @port}, v6_node]

      bin = Compact.encode_nodes6(mixed)
      assert byte_size(bin) == Compact.node_info6_size()
      assert Compact.decode_nodes6(bin) == [v6_node]
    end

    test "encode_ipv6_peer/decode_ipv6_peers round-trip" do
      bin = encode_ipv6_peer_ok!(@v6, @port)
      assert byte_size(bin) == Compact.ipv6_peer_info_size()
      assert [%Peer{ip: @v6, port: @port}] = Compact.decode_ipv6_peers(bin)
    end

    test "decode_nodes6 and decode_ipv6_peers ignore truncated tails" do
      node_bin = encode_node6_ok!(@node_id, @v6, @port)
      peer_bin = encode_ipv6_peer_ok!(@v6, @port)

      assert Compact.decode_nodes6(node_bin <> <<9>>) == [%{id: @node_id, ip: @v6, port: @port}]
      assert Compact.decode_ipv6_peers(peer_bin <> <<9>>) == [%Peer{ip: @v6, port: @port}]
    end

    test "encode_node6 and encode_ipv6_peer reject IPv4 and bad ports" do
      assert Compact.encode_node6(@node_id, @v4, @port) == {:error, :unsupported_ip}
      assert Compact.encode_node6(<<0::128>>, @v6, @port) == {:error, :unsupported_ip}
      assert Compact.encode_ipv6_peer(@v4, @port) == {:error, :unsupported_ip}
      assert Compact.encode_ipv6_peer(@v6, 0) == {:error, :unsupported_ip}
    end
  end

  describe "size constants" do
    test "expose BEP 5/23/32 entry sizes" do
      assert Compact.node_info_size() == 26
      assert Compact.peer_info_size() == 6
      assert Compact.node_info6_size() == 38
      assert Compact.ipv6_peer_info_size() == 18
    end
  end

  defp encode_node_ok(id, ip, port) do
    case Compact.encode_node(id, ip, port) do
      bin when is_binary(bin) -> {:ok, bin}
      other -> other
    end
  end

  defp encode_node_ok!(id, ip, port) do
    assert bin = Compact.encode_node(id, ip, port)
    bin
  end

  defp encode_peer_ok!(ip, port) do
    assert bin = Compact.encode_peer(ip, port)
    bin
  end

  defp encode_node6_ok!(id, ip, port) do
    assert bin = Compact.encode_node6(id, ip, port)
    bin
  end

  defp encode_ipv6_peer_ok!(ip, port) do
    assert bin = Compact.encode_ipv6_peer(ip, port)
    bin
  end
end

defmodule DHTLookupPeerStoreHelpersTest do
  use ExUnit.Case, async: true

  alias DHT.{Lookup, PeerStore, RoutingTables}

  @local <<0::160>>
  @target <<100::160>>
  @now 2_000_000

  defp contact(n), do: %{id: <<n::160>>, ip: {10, 0, 0, 1}, port: 6881}

  describe "Lookup improved?/3 and merge_nodes duplicate ids" do
    test "improved?/3 with no prior queries mirrors any-unqueried check" do
      unqueried = [%{id: contact(105).id, queried?: false}]
      assert Lookup.improved?(unqueried, [], @target)
      refute Lookup.improved?([%{id: contact(105).id, queried?: true}], [], @target)
    end

    test "improved?/3 detects closer unqueried nodes versus farthest queried distance" do
      far = contact(200)
      closer = contact(105)
      farther = contact(172)

      shortlist = [
        %{id: far.id, queried?: true},
        %{id: closer.id, queried?: false}
      ]

      assert Lookup.improved?(shortlist, [far.id], @target)

      shortlist_all_far = [
        %{id: far.id, queried?: true},
        %{id: farther.id, queried?: false}
      ]

      refute Lookup.improved?(shortlist_all_far, [far.id], @target)
    end

    test "merge_nodes/3 preserves queried? when the same id is merged again" do
      id = contact(50).id
      shortlist = [%{id: id, queried?: true}]

      merged = Lookup.merge_nodes(shortlist, [contact(50)], @target)
      assert [%{id: ^id, queried?: true}] = Enum.filter(merged, &(&1.id == id))
    end
  end

  describe "Lookup RoutingTables shortlist paths" do
    test "initial_shortlist/2 and refresh_shortlist/3 work on dual routing tables" do
      tables =
        RoutingTables.new(@local)
        |> RoutingTables.insert(contact(100), now_ms: @now)
        |> RoutingTables.insert(
          %{id: <<51::160>>, ip: {0x2001, 0, 0, 0, 0, 0, 0, 1}, port: 6882},
          now_ms: @now
        )

      shortlist = Lookup.initial_shortlist(tables, @target)
      assert length(shortlist) == 2
      assert Enum.all?(shortlist, &(Map.has_key?(&1, :queried?) and &1.queried? == false))

      marked = Enum.map(shortlist, &%{&1 | queried?: true})
      refreshed = Lookup.refresh_shortlist(tables, @target, marked)
      assert Enum.all?(refreshed, & &1.queried?)
    end
  end

  describe "PeerStore prune/trim and dedup" do
    test "get/3 drops expired peers and prune/2 removes empty hashes" do
      hash = <<61::160>>
      peer = %Peer{ip: {198, 51, 100, 1}, port: 6881}

      store =
        %{}
        |> PeerStore.put(hash, peer, now_ms: @now, ttl_ms: 1_000)
        |> PeerStore.put(<<62::160>>, peer, now_ms: @now, ttl_ms: 60_000)

      later = @now + 2_000
      assert PeerStore.get(store, hash, now_ms: later) == []
      assert [%Peer{}] = PeerStore.get(store, <<62::160>>, now_ms: later)

      pruned = PeerStore.prune(store, now_ms: later)
      refute Map.has_key?(pruned, hash)
      assert Map.has_key?(pruned, <<62::160>>)
    end

    test "put/4 deduplicates same ip/port and trim_hashes caps hash count at 256" do
      hash = <<63::160>>
      peer = %Peer{ip: {10, 0, 0, 2}, port: 6882}

      store =
        PeerStore.put(%{}, hash, peer, now_ms: @now)
        |> PeerStore.put(hash, peer, now_ms: @now + 1, ttl_ms: 5_000)

      assert [%Peer{ip: {10, 0, 0, 2}, port: 6882}] = PeerStore.get(store, hash, now_ms: @now + 1)

      overflow =
        Enum.reduce(1..257, %{}, fn n, acc ->
          PeerStore.put(acc, <<n::160>>, peer, now_ms: @now)
        end)

      assert map_size(overflow) == 256
    end
  end
end

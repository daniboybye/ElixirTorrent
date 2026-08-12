defmodule Cycle3CodecQueueNatCoverageTest do
  @moduledoc """
  Coverage for three independent fail-closed surfaces:

    * the hand-written bencode prefix parser used to split a BEP 9
      `ut_metadata` data message (dictionary followed by raw metadata bytes) —
      it runs on unvalidated bytes from a remote peer, so every malformed shape
      must throw rather than match a later clause;
    * `Peer.ConnectionManager.Queue`, which bounds how many endpoints a remote
      peer can push at us via BEP 11 PEX so one chatty peer cannot fill the dial
      queue;
    * `NAT.PortMapper`'s retry schedule, which decides how often we re-attempt
      NAT-PMP / UPnP port mapping and when to give up on a method entirely.
  """
  use ExUnit.Case, async: false

  alias Magnet.UtMetadata
  alias Peer.ConnectionManager.Queue

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "UtMetadata.split_bencoded_prefix/1 on well-formed values" do
    test "splits the dictionary from the trailing metadata bytes" do
      payload = Bento.encode!(%{"msg_type" => 1, "piece" => 0}) <> "rawbytes"

      assert {:ok, %{"msg_type" => 1, "piece" => 0}, "rawbytes"} =
               UtMetadata.split_bencoded_prefix(payload)
    end

    test "an empty dictionary is still a dictionary" do
      assert {:ok, %{}, "tail"} = UtMetadata.split_bencoded_prefix("de" <> "tail")
    end

    test "a top-level string or list is not a BEP 9 message" do
      assert {:error, :expected_dictionary} = UtMetadata.split_bencoded_prefix("3:abcrest")
      assert {:error, :expected_dictionary} = UtMetadata.split_bencoded_prefix("0:rest")
      assert {:error, :expected_dictionary} = UtMetadata.split_bencoded_prefix("li1ei2eerest")
      assert {:error, :expected_dictionary} = UtMetadata.split_bencoded_prefix("lerest")
    end

    test "nested lists are parsed to the end of the outer list" do
      assert {:error, :expected_dictionary} = UtMetadata.split_bencoded_prefix("ll1:aee")
    end
  end

  describe "UtMetadata.split_bencoded_prefix/1 on malformed input" do
    test "rejects malformed integers" do
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("i-e")
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("i-0e")
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("ixe")
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("i12x")
    end

    test "rejects malformed strings" do
      # Length prefix that never reaches its colon.
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("12")
      # Declares more bytes than the message carries.
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("5:abc")
      # A digit start that is neither "0:" nor 1-9.
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("0x")
    end

    test "rejects unterminated containers" do
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("li1e")
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("d1:a1:b")
      assert {:error, :invalid_bencode} = UtMetadata.split_bencoded_prefix("x")
    end
  end

  describe "UtMetadata.assemble_pieces/2" do
    test "rejects a piece whose length disagrees with the handshake size" do
      # BEP 9: metadata_size comes from the extended handshake, and every piece
      # but the last must be exactly 16 KiB. A short piece means we lost bytes
      # or the peer is lying, so nothing may be assembled from it.
      pieces = %{0 => :binary.copy(<<0>>, 16_384), 1 => :binary.copy(<<0>>, 100)}

      assert {:error, :incomplete} = UtMetadata.assemble_pieces(pieces, 32_768)
    end
  end

  describe "Peer.ConnectionManager.Queue lookups" do
    test "get_peer/2 answers nil for an endpoint we never queued" do
      assert Queue.get_peer(%{}, {{192, 0, 2, 1}, 6881}) == nil
    end

    test "revoke_pex/3 ignores endpoints that are not queued" do
      queue = Queue.offer(%{}, [peer({192, 0, 2, 1}, 6881)], :discovery)

      # Endpoints are accepted both as raw {ip, port} and as %Peer{}.
      assert ^queue = Queue.revoke_pex(queue, remote_id(1), [{{198, 51, 100, 9}, 6881}])
      assert map_size(queue) == 1
    end
  end

  describe "Peer.ConnectionManager.Queue PEX retention caps" do
    test "the global PEX cap evicts entries once several suppliers fill the queue" do
      per_source = Queue.max_pex_per_source()

      queue =
        Enum.reduce(1..5, %{}, fn source_index, acc ->
          peers =
            for i <- 1..per_source do
              peer({10, source_index, div(i, 256), rem(i, 256)}, 6881)
            end

          Queue.offer(acc, peers, {:pex, remote_id(source_index)})
        end)

      # 5 suppliers x 64 = 320 PEX-only endpoints, trimmed to the global cap.
      assert map_size(queue) == Queue.max_global_pex_entries()
    end

    test "an endpoint discovery also knows survives PEX eviction" do
      per_source = Queue.max_pex_per_source()
      kept = peer({10, 9, 9, 9}, 6881)

      queue = Queue.offer(%{}, [kept], :discovery)

      queue =
        Enum.reduce(1..5, queue, fn source_index, acc ->
          peers =
            [kept] ++
              for i <- 1..per_source do
                peer({10, source_index, div(i, 256), rem(i, 256)}, 6881)
              end

          Queue.offer(acc, peers, {:pex, remote_id(source_index)})
        end)

      assert Queue.get_peer(queue, {{10, 9, 9, 9}, 6881}) == kept
    end
  end

  describe "NAT.PortMapper mapping cycle" do
    test "a cycle with both methods dead sleeps until the next refresh" do
      state = %{
        failures: 3,
        method_failures: %{natpmp: 5, upnp: 5},
        dead_methods: MapSet.new([:natpmp, :upnp])
      }

      assert {:noreply, next} = NAT.PortMapper.handle_info(:map_ports, state)

      # Nothing was attempted, so the failure counter resets rather than ramping.
      assert next.failures == 0
      assert next.dead_methods == MapSet.new([:natpmp, :upnp])
      flush_map_ports()
    end

    test "a cycle with no default gateway counts a failure and backs off" do
      # Without an IPv4 address there is no /24 to guess the gateway from, so
      # NAT-PMP cannot even be attempted.
      with_no_ipv4()

      state = %{
        failures: 0,
        method_failures: %{natpmp: 0, upnp: 0},
        dead_methods: MapSet.new([:upnp])
      }

      assert {:noreply, next} = NAT.PortMapper.handle_info(:map_ports, state)

      assert next.failures == 1
      flush_map_ports()
    end
  end

  describe "Torrents.list/0" do
    test "ignores supervised children that are not torrents" do
      before = Torrents.list()

      {:ok, stray} =
        DynamicSupervisor.start_child(Torrents, %{
          id: make_ref(),
          start: {Agent, :start_link, [fn -> :not_a_torrent end]},
          restart: :temporary
        })

      on_exit(fn -> DynamicSupervisor.terminate_child(Torrents, stray) end)

      assert Torrents.list() == before
    end
  end

  ## helpers -----------------------------------------------------------------

  defp peer(ip, port), do: %Peer{ip: ip, port: port}

  defp remote_id(n), do: <<n::160>>

  # NAT.PortMapper re-arms its own timer at the end of a cycle; drop that
  # message so it cannot leak into a later assertion in this process.
  defp flush_map_ports do
    receive do
      :map_ports -> :ok
    after
      0 -> :ok
    end
  end

  defp with_no_ipv4 do
    key = Acceptor.ip_cache_key()
    previous = :persistent_term.get(key, :none)

    on_exit(fn ->
      case previous do
        :none -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end)

    :persistent_term.put(key, %{
      inet: nil,
      inet6: nil,
      inet6_all: [],
      multicast_interfaces: %{inet: [], inet6: []}
    })
  end
end

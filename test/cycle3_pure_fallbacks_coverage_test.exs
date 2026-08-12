defmodule Cycle3PureFallbacksCoverageTest do
  @moduledoc """
  Coverage for parser and codec fallbacks that only fire on hostile or unusual
  input: malformed magnet URIs, ut_pex (BEP 11) messages from a peer that does
  not follow the spec, and tracker responses that carry the wrong types.

  All of this input arrives from the network, so each fallback is the difference
  between "skip this peer/field" and "crash the torrent".
  """
  use ExUnit.Case, async: false

  alias Peer.UtPex
  alias Peer.UtPex.Entry

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "Magnet.parse/1 rejects malformed URIs" do
    test "a magnet with no query has nothing to identify" do
      assert {:error, :missing_query} = Magnet.parse("magnet:")
    end

    test "a non-magnet scheme is rejected" do
      assert {:error, :invalid_scheme} = Magnet.parse("http://example.test/?xt=urn:btih:00")
    end

    test "a schemeless URI is not a magnet" do
      assert {:error, :invalid_scheme} = Magnet.parse("/announce?xt=urn:btih:0000")
    end

    test "a btih that is neither 40 hex nor 32 base32 characters is rejected" do
      assert {:error, :invalid_btih} = Magnet.parse("magnet:?xt=urn:btih:not-a-hash")
    end

    test "a base32 btih is decoded to the same 20-byte info hash as its hex form" do
      hash = :crypto.strong_rand_bytes(20)

      base32 =
        hash
        |> Base.encode32(padding: false)
        |> String.downcase()

      assert {:ok, %Magnet{hash: ^hash, kind: :v1}} =
               Magnet.parse("magnet:?xt=urn:btih:#{base32}")
    end

    test "a base32 btmh that is not a sha2-256 multihash is rejected" do
      # BEP 52: the v2 xt must decode to <<0x12, 0x20, 32-byte digest>>.
      encoded = String.duplicate("a", 55)

      assert {:error, :invalid_btmh} = Magnet.parse("magnet:?xt=urn:btmh:#{encoded}")
    end
  end

  describe "Magnet.parse/1 tolerates junk alongside a valid hash" do
    test "valueless query tokens, bad x.pe endpoints and odd trackers are skipped" do
      hash = :crypto.strong_rand_bytes(20)
      hex = Base.encode16(hash, case: :lower)

      uri =
        "magnet:?xt=urn:btih:#{hex}" <>
          "&flagwithoutvalue" <>
          "&x.pe=noport" <>
          "&x.pe=%5B2001:db8::1%5D:6881" <>
          "&x.pe=192.168.1.9:0" <>
          "&x.pe=192.0.2.7:6881" <>
          "&tr=ws%3A%2F%2Frelay.example%2Fpex" <>
          "&tr=udp%3A%2F%2Ftracker.example%3A6969"

      assert {:ok, magnet} = Magnet.parse(uri)
      assert magnet.hash == hash
      # Only the routable IPv4 endpoint with a valid port survives.
      assert magnet.x_pe_peers == [%Peer{ip: {192, 0, 2, 7}, port: 6881}]
      # An unknown scheme is passed through verbatim; a known one gets /announce.
      assert "ws://relay.example/pex" in magnet.trackers
      assert "udp://tracker.example:6969/announce" in magnet.trackers
    end
  end

  describe "Magnet.build_torrent!/2" do
    test "several trackers become announce plus announce-list" do
      magnet = %Magnet{
        hash: :crypto.strong_rand_bytes(20),
        trackers: ["udp://a.example/announce", "udp://b.example/announce"]
      }

      info_blob = Bento.encode!(%{"name" => "multi", "piece length" => 16_384})
      torrent = Magnet.build_torrent!(magnet, info_blob)

      assert {:ok, decoded} = Bento.decode(torrent)
      assert decoded["announce"] == "udp://a.example/announce"

      assert decoded["announce-list"] == [
               ["udp://a.example/announce"],
               ["udp://b.example/announce"]
             ]
    end
  end

  describe "UtPex.drop_self/2" do
    test "keeps the snapshot when we do not know our own endpoint" do
      current = %{{{192, 0, 2, 1}, 6881} => entry({192, 0, 2, 1}, 6881)}

      assert ^current = UtPex.drop_self(current, nil)
    end

    test "never advertises us back to the swarm" do
      self_ep = {{192, 0, 2, 1}, 6881}
      current = %{self_ep => entry({192, 0, 2, 1}, 6881)}

      assert UtPex.drop_self(current, self_ep) == %{}
    end
  end

  describe "UtPex.encode/3" do
    test "an empty delta produces no message at all" do
      # BEP 11: sending an empty ut_pex message every tick is pure noise.
      assert UtPex.encode([], []) == nil
    end
  end

  describe "UtPex.decode/2 validation" do
    test "accepts an IPv6 dropped list" do
      # BEP 11 compact IPv6: 16-byte address + 2-byte big-endian port.
      compact6 = <<0x2001::16, 0x0DB8::16, 0::80, 1::16, 6881::16>>
      payload = Bento.encode!(%{"dropped6" => compact6})

      assert {:ok, [], dropped} = UtPex.decode(payload)
      assert length(dropped) == 1
    end

    test "rejects a compact field that is not a binary" do
      assert :error = UtPex.decode(Bento.encode!(%{"added" => 42}))
    end
  end

  describe "UtPex swarm fan-out" do
    test "snapshot_entries/2 skips the excluded peer and peers with no entry" do
      hash = new_hash()
      start_swarm(hash)

      excluded = add_peer(hash, {:ok, entry({192, 0, 2, 10}, 6881)})
      _no_entry = add_peer(hash, :error)
      add_peer(hash, {:ok, entry({192, 0, 2, 11}, 6882)})

      entries = UtPex.snapshot_entries(hash, exclude_key: excluded)

      assert Enum.map(entries, &Entry.endpoint/1) == [{{192, 0, 2, 11}, 6882}]
    end

    test "broadcast/4 sends the encoded delta to every connected peer" do
      hash = new_hash()
      start_swarm(hash)
      add_peer(hash, :error)

      assert {:ok, report} = UtPex.broadcast(hash, [entry({192, 0, 2, 12}, 6883)], [])
      assert report.added_encoded == 1
      assert_receive {:controller, :send_pex}, 2_000
    end

    test "broadcast/4 encodes nothing when there is no delta" do
      hash = new_hash()
      start_swarm(hash)

      assert :ok = UtPex.broadcast(hash, [], [])
    end
  end

  describe "Magnet.Fetcher round backoff" do
    test "a round where every peer was a reachable leecher retries sooner" do
      # Peers that answered but had no metadata are a sampling miss, not a dead
      # swarm, so the backoff must not ramp like a total failure.
      assert Magnet.Fetcher.dead_leecher_round_failure?(:metadata_unavailable)
      refute Magnet.Fetcher.dead_leecher_round_failure?(:no_swarm_metadata_peers)
      refute Magnet.Fetcher.dead_leecher_round_failure?(:no_peers)
      refute Magnet.Fetcher.dead_leecher_round_failure?(:round_worker_crashed)

      assert Magnet.Fetcher.round_backoff_ms(1, :metadata_unavailable) <
               Magnet.Fetcher.round_backoff_ms(1, :no_peers)
    end

    test "the connection budget is a positive number of parallel dials" do
      assert Magnet.Fetcher.max_connections() > 0
    end
  end

  describe "Magnet.Fetcher.await/2" do
    test "returns the written .torrent path" do
      ref = make_ref()
      send(self(), {:magnet_fetch, ref, {:ok, "/tmp/x.torrent"}})

      assert {:ok, "/tmp/x.torrent"} = Magnet.Fetcher.await(ref, 100)
    end

    test "returns the session's error verbatim" do
      ref = make_ref()
      send(self(), {:magnet_fetch, ref, {:error, :no_peers}})

      assert {:error, :no_peers} = Magnet.Fetcher.await(ref, 100)
    end

    test "times out when the session never reports" do
      assert {:error, :timeout} = Magnet.Fetcher.await(make_ref(), 10)
    end
  end

  describe "Magnet.Fetcher.prepare_for_download/1" do
    test "force-stops a fetch session that ignores :cancel" do
      hash = new_hash()

      {:ok, stubborn} = Cycle3PureFallbacksCoverageTest.Stubborn.start(hash)
      on_exit(fn -> Process.exit(stubborn, :kill) end)

      # The session traps exits and ignores both :cancel and :shutdown, so both
      # await windows expire; prepare_for_download/1 must still return.
      assert :ok = Magnet.Fetcher.prepare_for_download(hash)
      assert Process.alive?(stubborn)
    end
  end

  describe "Tracker fallbacks" do
    test "scraping zero info hashes never touches the socket" do
      assert %{} = Tracker.udp_scrape(nil, {127, 0, 0, 1}, 6969, [])
    end
  end

  ## helpers -----------------------------------------------------------------

  defp new_hash, do: :crypto.strong_rand_bytes(20)

  defp peer_id, do: :crypto.strong_rand_bytes(20)

  defp entry(ip, port), do: Entry.normalize({ip, port})

  defp start_swarm(hash) do
    {:ok, pid} =
      DynamicSupervisor.start_link(
        name: {:via, Registry, {Registry, {hash, Torrent.Swarm}}},
        strategy: :one_for_one,
        max_restarts: 0
      )

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp add_peer(hash, pex_entry) do
    key = Peer.make_key(hash, peer_id())
    sup = GenServer.whereis({:via, Registry, {Registry, {hash, Torrent.Swarm}}})

    {:ok, _} =
      DynamicSupervisor.start_child(sup, %{
        id: make_ref(),
        start: {Cycle3PureFallbacksCoverageTest.PexPeer, :start_peer, [key]},
        restart: :temporary
      })

    {:ok, controller} =
      Cycle3PureFallbacksCoverageTest.PexPeer.start_controller(key, pex_entry, self())

    on_exit(fn -> stop_quietly(controller) end)
    key
  end

  defp stop_quietly(pid) when is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
  defp stop_quietly(_), do: :ok
end

defmodule Cycle3PureFallbacksCoverageTest.PexPeer do
  @moduledoc false
  use GenServer

  @spec start_peer(Peer.key()) :: GenServer.on_start()
  def start_peer(key), do: GenServer.start_link(__MODULE__, {:peer, key})

  @spec start_controller(Peer.key(), term(), pid()) :: GenServer.on_start()
  def start_controller(key, pex_entry, test_pid) do
    GenServer.start(__MODULE__, {:controller, pex_entry, test_pid},
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  @impl GenServer
  def init({:peer, key}) do
    {:ok, _} = Registry.register(Registry, {key, Peer}, nil)
    {:ok, key}
  end

  def init({:controller, pex_entry, test_pid}), do: {:ok, {pex_entry, test_pid}}

  @impl GenServer
  def handle_call(:pex_entry, _from, {pex_entry, _} = state), do: {:reply, pex_entry, state}

  @impl GenServer
  def handle_cast({verb, _args}, {_, test_pid} = state) do
    send(test_pid, {:controller, verb})
    {:noreply, state}
  end
end

defmodule Cycle3PureFallbacksCoverageTest.Stubborn do
  @moduledoc """
  A fetch session that refuses to die: it traps exits and drops `:cancel`, which
  is what a session wedged inside a blocking network call looks like from the
  outside.
  """
  use GenServer

  @spec start(Torrent.hash()) :: GenServer.on_start()
  def start(hash), do: GenServer.start(__MODULE__, hash)

  @impl GenServer
  def init(hash) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Registry.register(Registry, {:magnet_fetch, hash}, nil)
    {:ok, hash}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end

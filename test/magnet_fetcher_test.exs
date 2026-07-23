defmodule Magnet.FetcherTest do
  use ExUnit.Case, async: true

  test "run rejects trackerless magnets when DHT is disabled" do
    magnet = %Magnet{
      hash: <<0::160>>,
      trackers: [],
      x_pe_peers: [],
      display_name: nil
    }

    previous = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)

    assert {:error, :missing_trackers} = Magnet.Fetcher.run(magnet)
  end

  test "run starts persistent session and reports round progress" do
    magnet = %Magnet{
      hash: <<0::160>>,
      trackers: [],
      x_pe_peers: [%Peer{ip: {127, 0, 0, 1}, port: 6881}],
      display_name: nil
    }

    previous = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Magnet.Fetcher.cancel(magnet.hash)
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)

    assert {:ok, ref} = Magnet.Fetcher.run(magnet, self())
    assert is_reference(ref)

    assert_receive {:magnet_fetch_progress, ^ref, progress}, 20_000
    assert progress.round == 1
    assert is_integer(progress.peers_known)
    assert is_integer(progress.peers_tried)
    assert progress.status == "fetching metadata"

    refute_receive {:magnet_fetch, ^ref, _}, 1_000
  end

  test "round_backoff_ms increases with cap" do
    assert Magnet.Fetcher.round_backoff_ms(1) == 30_000
    assert Magnet.Fetcher.round_backoff_ms(2) == 35_000
    assert Magnet.Fetcher.round_backoff_ms(19) == 120_000
    assert Magnet.Fetcher.round_backoff_ms(100) == 120_000
  end

  test "round_backoff_ms caps dead-leecher sampling misses at 15s" do
    assert Magnet.Fetcher.round_backoff_ms(1, {:metadata_unavailable, [:peer_died]}) == 15_000
    assert Magnet.Fetcher.round_backoff_ms(8, {:metadata_unavailable, [:peer_died]}) == 15_000
    assert Magnet.Fetcher.dead_leecher_round_failure?({:metadata_unavailable, [:peer_died]})
    assert Magnet.Fetcher.dead_leecher_round_failure?({:metadata_unavailable, [:no_ut_metadata]})

    refute Magnet.Fetcher.dead_leecher_round_failure?({:metadata_unavailable, [:peer_died, :timeout]})
    refute Magnet.Fetcher.dead_leecher_round_failure?(:no_peers)
  end

  test "max_fetch_lifetime_ms caps persistent metadata fetch wall clock" do
    assert Magnet.Fetcher.max_fetch_lifetime_ms() == 24 * 60 * 60 * 1_000
  end

  test "discover_and_merge_peers merges and counts new peers" do
    magnet = %Magnet{
      hash: <<1::160>>,
      trackers: [],
      x_pe_peers: [
        %Peer{ip: {1, 2, 3, 4}, port: 6881},
        %Peer{ip: {5, 6, 7, 8}, port: 6882}
      ],
      display_name: nil
    }

    previous = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)

    known = %{{{1, 2, 3, 4}, 6881} => %Peer{ip: {1, 2, 3, 4}, port: 6881}}

    {merged, peers_new, _trackers} =
      Magnet.Fetcher.discover_and_merge_peers(magnet, [], known)

    assert map_size(merged) == 2
    assert peers_new == 1
  end

  test "select_peers_for_round returns all known peers up to cap" do
    peers = %{
      {{1, 1, 1, 1}, 6881} => %Peer{ip: {1, 1, 1, 1}, port: 6881},
      {{2, 2, 2, 2}, 6882} => %Peer{ip: {2, 2, 2, 2}, port: 6882}
    }

    attempts = %{{{1, 1, 1, 1}, 6881} => 3}

    selected = Magnet.Fetcher.select_peers_for_round(peers, attempts)
    assert length(selected) == 2
    assert Enum.any?(selected, fn
      %Peer{ip: {2, 2, 2, 2}} -> true
      _ -> false
    end)
  end

  test "select_peers_for_round prefers ipv6 peers when truncating to cap" do
    v6 = %Peer{ip: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}, port: 6881}

    peers =
      1..65
      |> Enum.map(fn octet ->
        %Peer{ip: {octet, octet, octet, octet}, port: 6880 + octet}
      end)
      |> then(fn v4_list -> [v6 | v4_list] end)
      |> Map.new(fn %Peer{ip: ip, port: port} -> {{ip, port}, %Peer{ip: ip, port: port}} end)

    selected = Magnet.Fetcher.select_peers_for_round(peers, %{})
    assert length(selected) == 60

    assert Enum.any?(selected, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end),
           "expected at least one ipv6 peer in the truncated round batch"
  end

  test "announce_dht_for_metadata starts DHT announce lookup when enabled" do
    hash = <<9::160>>

    previous = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: true)

    assert :ok = Magnet.Fetcher.announce_dht_for_metadata(hash)
    assert eventually(fn -> dht_announce_lookup?(hash) end)
  end

  test "discover_and_merge_peers announces to DHT before get_peers when enabled" do
    hash = <<10::160>>

    previous_dht = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :dht, previous_dht)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: true, lookup_timeout_ms: 50)

    magnet = %Magnet{
      hash: hash,
      trackers: [],
      x_pe_peers: [],
      display_name: nil
    }

    task = Task.async(fn -> Magnet.Fetcher.discover_and_merge_peers(magnet, [], %{}) end)

    assert eventually(fn -> dht_announce_lookup?(hash) end, 200)
    Task.shutdown(task, :brutal_kill)
  end

  test "dht deep retry delay stays within round extension budget" do
    assert Magnet.Fetcher.dht_deep_retry_delay_ms() == 13_000
    assert Magnet.Fetcher.dht_deep_retry_delay_ms() <= 15_000
  end

  test "take_background_dht_peers consumes completed background results once" do
    hash = <<11::160>>
    peer = %Peer{ip: {8, 8, 8, 8}, port: 6881}
    table = :magnet_fetcher_dht_background

    assert [] = Magnet.Fetcher.take_background_dht_peers(hash)
    :ets.insert(table, {hash, {:done, [peer]}})

    on_exit(fn -> safe_ets_delete(table, hash) end)

    assert Magnet.Fetcher.take_background_dht_peers(hash) == [peer]
    assert Magnet.Fetcher.take_background_dht_peers(hash) == []
  end

  test "dht_background_pending? reflects in-flight background lookup" do
    hash = <<12::160>>
    table = :magnet_fetcher_dht_background

    refute Magnet.Fetcher.dht_background_pending?(hash)
    :ets.insert(table, {hash, :pending})

    on_exit(fn -> safe_ets_delete(table, hash) end)

    assert Magnet.Fetcher.dht_background_pending?(hash)
  end

  defp dht_announce_lookup?(hash) when is_binary(hash) do
    %{lookups: lookups} = :sys.get_state(DHT)

    Enum.any?(Map.values(lookups), fn
      %{purpose: :announce, hash: ^hash} -> true
      _ -> false
    end)
  end

  test "tracker_await_timeout_ms scales with tracker count" do
    magnet = %Magnet{hash: <<0::160>>, trackers: List.duplicate("http://example.com/announce", 15)}

    assert Magnet.Fetcher.tracker_await_timeout_ms(magnet) == 105_000
  end

  test "cancel stops persistent session" do
    magnet = %Magnet{
      hash: <<2::160>>,
      trackers: [],
      x_pe_peers: [%Peer{ip: {127, 0, 0, 1}, port: 6881}],
      display_name: nil
    }

    previous = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Magnet.Fetcher.cancel(magnet.hash)
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)

    assert {:ok, ref} = Magnet.Fetcher.run(magnet, self())
    assert_receive {:magnet_fetch_progress, ^ref, _progress}, 5_000
    assert :ok = Magnet.Fetcher.cancel(magnet.hash)
    assert_receive {:magnet_fetch, ^ref, {:error, :cancelled}}, 5_000
    assert eventually(fn -> Registry.lookup(Registry, {:magnet_fetch, magnet.hash}) == [] end)
  end

  defp eventually(fun, attempts \\ 50) do
    if fun.() or attempts <= 0 do
      fun.()
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp safe_ets_delete(table, key) do
    case :ets.info(table) do
      :undefined -> :ok
      _ -> :ets.delete(table, key)
    end
  end

  test "prepare_for_download cancels fetch session and stops bootstrap" do
    magnet = %Magnet{
      hash: <<3::160>>,
      trackers: [],
      x_pe_peers: [%Peer{ip: {127, 0, 0, 1}, port: 6881}],
      display_name: nil
    }

    previous = Application.get_env(:elixir_torrent, :dht, [])

    on_exit(fn ->
      Magnet.Fetcher.prepare_for_download(magnet.hash)
      Application.put_env(:elixir_torrent, :dht, previous)
    end)

    Application.put_env(:elixir_torrent, :dht, enabled: false)

    assert {:ok, _ref} = Magnet.Fetcher.run(magnet, self())
    assert Magnet.Fetcher.fetch_session_active?(magnet.hash)
    :ok = Magnet.Fetcher.prepare_for_download(magnet.hash)
    refute Magnet.Fetcher.fetch_session_active?(magnet.hash)
    refute Magnet.Bootstrap.active?(magnet.hash)
  end

  test "mark_peers_attempted increments attempt counts" do
    peers = [%Peer{ip: {9, 9, 9, 9}, port: 6881}]
    attempts = Magnet.Fetcher.mark_peers_attempted(%{}, peers)
    assert attempts[{{9, 9, 9, 9}, 6881}] == 1
    attempts = Magnet.Fetcher.mark_peers_attempted(attempts, peers)
    assert attempts[{{9, 9, 9, 9}, 6881}] == 2
  end
end

defmodule TorrentPrivateTest do
  use ExUnit.Case, async: true

  test "private? reads private flag from torrent metadata" do
    metadata = %{
      "info" => %{
        "name" => "secret",
        "private" => 1,
        "piece length" => 16_384,
        "pieces" => <<0::160>>
      }
    }

    torrent = %Torrent{
      hash: <<0::160>>,
      metadata: metadata,
      left: 100,
      last_index: 0,
      last_piece_length: 100,
      private?: true
    }

    assert Torrent.private?(torrent)
    assert Torrent.private?(metadata)
    refute Torrent.private?(%Torrent{torrent | metadata: put_in(metadata, ["info", "private"], 0)})
  end
end

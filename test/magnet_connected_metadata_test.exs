defmodule MagnetConnectedMetadataTest do
  use ExUnit.Case, async: true

  @connection_ex Path.expand("../lib/elixir_torrent/magnet/connection.ex", __DIR__)
  @connected_ex Path.expand("../lib/elixir_torrent/magnet/connected_metadata.ex", __DIR__)

  test "open_swarm proceeds on metadata_size without requiring unchoke (BEP 9)" do
    source = File.read!(@connection_ex)

    assert source =~ "wait_controller_ready(key, info)"
    assert source =~ "Peer.Sender.deactivate(key)"
    assert source =~ "metadata_ready transport=swarm"
    refute source =~ "info.unchoked? == true and is_integer(metadata_size)"
    assert source =~ "is_integer(metadata_size) and metadata_size > 0"
    assert source =~ "BEP 9: ut_metadata exchange does not require an unchoke on the swarm path"
  end

  test "wait_controller_ready proceeds without metadata_size when ut_metadata is advertised" do
    source = File.read!(@connection_ex)

    assert source =~ "Peer.LTEP.Session.peer_supports?(info.ltep, @ut_metadata)"
    assert source =~ "metadata_size=unknown ut_metadata=true"
    assert source =~ "learn total_size from the data message"
    refute source =~ "metadata_seeder?(info) and System.monotonic_time(:millisecond) >= deadline"
  end

  test "connected metadata swarm path probes ut_metadata without blocking on metadata_size" do
    source = File.read!(@connected_ex)

    assert source =~ "metadata_peer_candidate?(info)"
    assert source =~ "metadata_size in the LTEP handshake is optional"
    assert source =~ "Connection.download_all_pieces/2"
    refute source =~ "do_wait_metadata_ready_poll"
    refute source =~ "do_wait_metadata_ready("
  end

  test "connected metadata labels peer death during LTEP wait distinctly from pending size" do
    source = File.read!(@connected_ex)

    assert source =~ "do_wait_for_ut_metadata"
    assert source =~ ":error -> {:error, :peer_died}"
    refute source =~ ":error -> {:error, :metadata_size_pending}"
  end

  test "connected metadata happy path still accepts metadata_size from eligible peers" do
    source = File.read!(@connected_ex)

    assert source =~ "metadata_peer_eligible?(info)"
    assert source =~ "metadata_peer_eligible?(info) ->"
  end

  test "connected metadata logs peer death fallthrough and aggregates failures" do
    source = File.read!(@connected_ex)

    assert source =~ "metadata_peer_died"
    assert source =~ "trying_next_peer"
    assert source =~ "metadata_round_exhausted"
    assert source =~ "{:exit, reason}"
    assert source =~ "@min_peers_for_round 4"
    assert source =~ "@metadata_parallel 8"
    assert source =~ "sampling problem"
  end
end

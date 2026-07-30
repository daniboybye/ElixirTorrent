defmodule PeerDiscoveryStartedAnnouncesTest do
  use ExUnit.Case, async: true

  alias PeerDiscovery.StartedAnnounces

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "records and forgets a hash for the current process lifetime" do
    hash = :crypto.strong_rand_bytes(20)

    refute StartedAnnounces.sent?(hash)

    assert :ok = StartedAnnounces.put(hash)
    assert StartedAnnounces.sent?(hash)

    # Idempotent: the table only ever answers "this BEAM already sent started".
    assert :ok = StartedAnnounces.put(hash)
    assert StartedAnnounces.sent?(hash)

    assert :ok = StartedAnnounces.delete(hash)
    refute StartedAnnounces.sent?(hash)
  end

  test "dropping the persisted session forgets the started record" do
    torrent = sample_torrent()
    StartedAnnounces.put(torrent.hash)

    # Removing a torrent ends its tracker session (BEP 3), so a later re-add is a
    # new session and owes `started` again even inside the same BEAM.
    assert :ok = Torrent.Session.delete(torrent.hash)

    refute StartedAnnounces.sent?(torrent.hash)
  end

  test "the started record is never part of the persisted session payload" do
    torrent = sample_torrent()
    on_exit(fn -> Torrent.Session.delete(torrent.hash) end)

    StartedAnnounces.put(torrent.hash)
    :ok = Torrent.Session.save(torrent.hash, torrent)

    assert {:ok, session} = Torrent.Session.load(torrent.hash)

    # The whole mechanism rests on this: nothing about tracker events reaches
    # disk, so a cold boot always reads an empty table and correctly treats the
    # first announce for a hash as a new session's `started`.
    assert session |> Map.keys() |> Enum.sort() ==
             [:added_at, :bitfield, :downloaded, :left, :peer_status, :uploaded]
  end

  defp sample_torrent do
    %Torrent{
      hash: :crypto.strong_rand_bytes(20),
      metadata: %{"info" => %{"name" => "started-record", "piece length" => 16_384}},
      left: 8_192,
      last_index: 0,
      last_piece_length: 8_192,
      bitfield: Torrent.Bitfield.make(1),
      peer_status: nil
    }
  end
end

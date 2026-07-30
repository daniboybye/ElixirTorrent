defmodule HTTPTrackerTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "HTTP tracker IPv6 connect options" do
    test "request! returns Error instead of raising CaseClauseError on badarg-prone IPv6 bind" do
      hash = :crypto.strong_rand_bytes(20)

      result =
        Tracker.request!(
          "http://127.0.0.1:1/announce",
          hash,
          [uploaded: 0, downloaded: 0, left: 16_384, event: Torrent.started()],
          http_timeout_ms: 50
        )

      assert match?(%Tracker.Response{}, result) or match?(%Tracker.Error{}, result)
    end
  end

  describe "BEP 3 HTTP announce events" do
    test "started, periodic, completed, and stopped announces use one-shot event keys" do
      torrent = sample_torrent()
      start_model(torrent)

      assert announce_query(torrent.hash)["event"] == "started"

      Torrent.Model.update_event(torrent.hash, Torrent.started())
      refute Map.has_key?(announce_query(torrent.hash), "event")

      Torrent.Model.downloaded_piece(torrent.hash, 0)
      assert announce_query(torrent.hash)["event"] == "completed"

      # A delayed response to an older periodic announce must not consume the
      # newly-raised completion transition.
      Torrent.Model.update_event(torrent.hash, Torrent.empty())
      assert announce_query(torrent.hash)["event"] == "completed"

      Torrent.Model.update_event(torrent.hash, Torrent.completed())
      refute Map.has_key?(announce_query(torrent.hash), "event")

      Torrent.Model.set_event(torrent.hash, Torrent.stopped())
      assert announce_query(torrent.hash)["event"] == "stopped"

      Torrent.Model.update_event(torrent.hash, Torrent.stopped())
      assert announce_query(torrent.hash)["event"] == "stopped"
    end

    test "the first restore of a process lifetime announces started again" do
      torrent = sample_torrent()
      on_exit(fn -> Torrent.Session.delete(torrent.hash) end)

      # A cold app restart: state comes off disk, but nothing has delivered
      # `started` for this hash in this BEAM. The tracker's session row for us is
      # gone (it saw our `stopped`, or timed us out), so BEP 3 wants `started` on
      # the first announce. Drive the real disk path, save → load → apply, the way
      # `Torrent.init/1` does at boot.
      PeerDiscovery.StartedAnnounces.delete(torrent.hash)
      :ok = Torrent.Session.save(torrent.hash, %{torrent | uploaded: 123})
      assert {:ok, session} = Torrent.Session.load(torrent.hash)

      resumed = Torrent.Session.apply(torrent, session)
      assert resumed.uploaded == 123
      assert resumed.event == Torrent.started()

      start_model(resumed)

      assert announce_query(torrent.hash)["event"] == "started"
    end

    test "a session restored in-process does not announce started again" do
      torrent = sample_torrent()
      PeerDiscovery.StartedAnnounces.delete(torrent.hash)

      # First resume of this process lifetime still owes `started` ...
      first = Torrent.Session.apply(torrent, sample_session(torrent))
      assert first.event == Torrent.started()

      # ... and a tracker accepting that announce is what opens the session from
      # the tracker's point of view (PeerDiscovery.Announce records it there).
      PeerDiscovery.StartedAnnounces.put(torrent.hash)

      # Second resume with only an in-process reconcile in between — pause then
      # add again, or a plain re-add of a hash whose `.term` file is still there.
      # The tracker already holds our session row, so this announce must carry no
      # event key at all; resending `started` would open a second one.
      resumed = Torrent.Session.apply(torrent, sample_session(torrent))
      assert resumed.event == Torrent.empty()

      start_model(resumed)

      refute Map.has_key?(announce_query(torrent.hash), "event")
    end
  end

  defp sample_torrent do
    hash = :crypto.strong_rand_bytes(20)
    piece_length = 8_192

    %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => "event-test",
          "length" => piece_length,
          "piece length" => 16_384
        }
      },
      left: piece_length,
      last_index: 0,
      last_piece_length: piece_length,
      bitfield: Torrent.Bitfield.make(1),
      peer_status: nil
    }
  end

  defp sample_session(torrent) do
    %{
      bitfield: Torrent.Bitfield.make(1),
      downloaded: 0,
      left: torrent.left,
      uploaded: 123,
      peer_status: nil
    }
  end

  defp start_model(torrent) do
    Torrent.Session.delete(torrent.hash)
    {:ok, pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      TestSupport.Sync.safe_stop(pid)
      Torrent.Session.delete(torrent.hash)
    end)
  end

  defp announce_query(hash) do
    [uploaded, downloaded, left, event] =
      Torrent.get(hash, [:uploaded, :downloaded, :left, :event])

    Tracker.build_http_announce_query(hash, uploaded, downloaded, left, event)
  end
end

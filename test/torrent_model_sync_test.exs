defmodule Torrent.ModelSyncTest do
  use ExUnit.Case, async: true

  alias Torrent.Bitfield
  alias Torrent.Model

  test "sync_progress reconciles counters without synthesizing a completed event" do
    torrent = %Torrent{
      hash: <<2::160>>,
      metadata: %{
        "info" => %{
          "name" => "clip.mp4",
          "length" => 32_768,
          "piece length" => 16_384,
          "pieces" => :crypto.hash(:sha, "a") <> :crypto.hash(:sha, "b")
        }
      },
      downloaded: 0,
      left: 32_768,
      event: Torrent.empty(),
      last_index: 1,
      last_piece_length: 16_384,
      bitfield:
        Bitfield.make(2)
        |> Bitfield.set(0, 1)
        |> Bitfield.set(1, 1)
    }

    synced = Model.reconcile_progress(torrent)

    assert synced.downloaded == 32_768
    assert synced.left == 0
    assert synced.peer_status == :seed
    assert synced.event == Torrent.empty()
  end

  test "sync_progress leaves partial downloads unchanged except counters" do
    torrent = %Torrent{
      hash: <<3::160>>,
      metadata: %{
        "info" => %{
          "name" => "clip.mp4",
          "length" => 32_768,
          "piece length" => 16_384,
          "pieces" => :crypto.hash(:sha, "a") <> :crypto.hash(:sha, "b")
        }
      },
      downloaded: 0,
      left: 32_768,
      last_index: 1,
      last_piece_length: 16_384,
      peer_status: 0,
      bitfield: Bitfield.make(2) |> Bitfield.set(0, 1)
    }

    synced = Model.reconcile_progress(torrent)

    assert synced.downloaded == 16_384
    assert synced.left == 16_384
    assert synced.peer_status == 0
  end
end

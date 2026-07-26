defmodule Torrent.SessionCheckpointTest do
  use ExUnit.Case, async: false

  alias Torrent.{Bitfield, Model, Session}

  setup do
    prev = File.cwd!()
    tmp = System.tmp_dir!() |> Path.join("et_checkpoint_#{System.unique_integer()}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(prev)
      File.rm_rf(tmp)
    end)

    :ok
  end

  test "checkpoint persists partial bitfield after downloaded_piece" do
    hash = <<42::160>>

    torrent = %Torrent{
      hash: hash,
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
      bitfield: Bitfield.make(2)
    }

    {:ok, pid} = Model.start_link(torrent)
    assert is_pid(pid)

    :ok = Model.downloaded_piece(hash, 0)

    send(pid, :checkpoint)
    TestSupport.Sync.sync(pid)

    assert {:ok, session} = Session.load(hash)
    assert session.downloaded == 16_384
    assert session.left == 16_384
    assert Bitfield.have?(session.bitfield, 0)
    refute Bitfield.have?(session.bitfield, 1)
  end

  test "checkpoint skips when nothing downloaded yet" do
    hash = <<43::160>>

    torrent = %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => "empty.mp4",
          "length" => 16_384,
          "piece length" => 16_384,
          "pieces" => :crypto.hash(:sha, "a")
        }
      },
      downloaded: 0,
      left: 16_384,
      last_index: 0,
      last_piece_length: 16_384,
      bitfield: Bitfield.make(1)
    }

    {:ok, pid} = Model.start_link(torrent)
    send(pid, :checkpoint)
    TestSupport.Sync.sync(pid)

    assert Session.load(hash) == :error
  end
end

defmodule TorrentResumeTest do
  use ExUnit.Case, async: true

  @torrent_ex Path.expand("../lib/elixir_torrent/torrent.ex", __DIR__)

  test "torrent supervisor uses rest_for_one with Resume last so verify exit does not restart Downloads" do
    source = File.read!(@torrent_ex)

    assert source =~ "strategy: :rest_for_one"
    refute source =~ "strategy: :one_for_all"

    resume_idx = :binary.match(source, "Resume.child_spec")
    controller_idx = :binary.match(source, "{Controller, hash}")

    assert resume_idx != :nomatch
    assert controller_idx != :nomatch
    assert elem(resume_idx, 0) > elem(controller_idx, 0)
  end

  test "fresh torrent without session defaults to verify_saved not full_scan" do
    source = File.read!(@torrent_ex)

    assert source =~ ":error -> {torrent, :verify_saved}"
    refute source =~ ":error -> {torrent, :full_scan}"
  end

  test "controller waits for resume_ready before scheduling pieces" do
    source =
      Path.expand("../lib/elixir_torrent/torrent/controller.ex", __DIR__)
      |> File.read!()

    refute source =~ "send_after(self(), {:next_piece, :random}, 2_000)"
    assert source =~ "def resume_ready"
    assert source =~ "handle_info(:resume_ready"
  end

  test "model periodically checkpoints partial session to disk" do
    source =
      Path.expand("../lib/elixir_torrent/torrent/model.ex", __DIR__)
      |> File.read!()

    assert source =~ "handle_info(:checkpoint"
    assert source =~ "Session.save(torrent.hash, torrent)"
    assert source =~ "@checkpoint_interval"
  end

  test "piece process coalesces subpiece writes before disk flush" do
    source =
      Path.expand("../lib/elixir_torrent/torrent/file_handle/piece.ex", __DIR__)
      |> File.read!()

    assert source =~ "pending_writes"
    assert source =~ "@flush_threshold"
    assert source =~ "flush_pending_writes"
  end
end

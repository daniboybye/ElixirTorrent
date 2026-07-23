defmodule PeerLogIdTest do
  use ExUnit.Case, async: true

  require Logger

  test "log_id keeps valid UTF-8 peer ids readable" do
    assert Peer.log_id("-qB5210-!r)QUe*WR_xa") == "-qB5210-!r)QUe*WR_xa"
  end

  test "log_id hex-encodes invalid UTF-8 peer ids for Logger safety" do
    invalid = <<0xFF, 0xFE, 0x80>>
    assert Peer.log_id(invalid) == Base.encode16(invalid, case: :lower)
    refute String.valid?(invalid)
  end

  test "Logger accepts messages built with log_id for invalid UTF-8" do
    invalid = <<0xFF, 0xFE, 0x80>>

    assert capture_log(fn ->
             Logger.info("[peer_download] peer=#{Peer.log_id(invalid)} hash=ABC test")
           end) =~ "peer=#{Peer.log_id(invalid)}"
  end

  defp capture_log(fun) do
    ExUnit.CaptureLog.capture_log(fun)
  end
end

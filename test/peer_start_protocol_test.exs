defmodule PeerStartProtocolTest do
  use ExUnit.Case, async: true

  @peer_source Path.expand("../lib/elixir_torrent/peer.ex", __DIR__)

  test "start_protocol delegates to Peer.Controller, not the peer supervisor" do
    source = File.read!(@peer_source)

    assert source =~ "Peer.Controller.start_protocol(key)"
    refute source =~ "GenServer.call(via(key), :start_protocol"
  end

  test "peer supervisor and controller use distinct Registry keys" do
    key = {<<0::160>>, <<1::160>>}

    peer_via = {:via, Registry, {Registry, {key, Peer}}}
    controller_via = {:via, Registry, {Registry, {key, Peer.Controller}}}

    assert peer_via == {:via, Registry, {Registry, {key, Peer}}}
    assert controller_via == {:via, Registry, {Registry, {key, Peer.Controller}}}
  end
end

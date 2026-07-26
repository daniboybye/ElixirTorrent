defmodule Magnet.TransportTest do
  use ExUnit.Case, async: true

  alias Peer.LTEP.Session

  test "connection struct records tcp utp and swarm transports" do
    for transport <- [:tcp, :utp, :swarm] do
      conn = %Magnet.Connection{
        socket: nil,
        peer_key: nil,
        ltep: Session.new(),
        metadata_size: 100,
        transport: transport,
        peer: %Peer{ip: {1, 2, 3, 4}, port: 6881},
        unchoked?: true,
        unchoke_since: 0
      }

      assert conn.transport == transport
    end
  end
end

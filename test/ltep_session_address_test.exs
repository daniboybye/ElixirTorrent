defmodule Peer.LTEP.SessionAddressTest do
  use ExUnit.Case, async: false

  alias Peer.LTEP.{Handshake, Session}

  test "outbound handshake includes listen port and global addresses when available" do
    session = Session.new([Peer.UtPex.Extension])
    {:ok, hs} = session |> Session.outbound_handshake() |> Handshake.decode()

    assert hs.m == %{"ut_pex" => 2}
    assert is_integer(hs.p) and hs.p > 0

    case Acceptor.ipv4_binary() do
      nil -> assert hs.ipv4 == nil
      ipv4 -> assert hs.ipv4 == ipv4
    end

    case Acceptor.ipv6_binary() do
      nil -> assert hs.ipv6 == nil
      ipv6 -> assert hs.ipv6 == ipv6
    end
  end
end

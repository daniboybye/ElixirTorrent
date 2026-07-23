defmodule Magnet.ConnectionTest do
  use ExUnit.Case, async: false

  alias Peer.LTEP.Handshake

  test "request_piece returns error on closed socket without crashing" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
    {:ok, port} = :inet.port(listen)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.close(socket)
    :gen_tcp.close(listen)

    peer_hs = %Handshake{m: %{"ut_metadata" => 1}, metadata_size: 4096}
    ltep = Peer.LTEP.Session.new() |> Peer.LTEP.Session.apply_peer_handshake(peer_hs)

    conn = %Magnet.Connection{
      socket: socket,
      ltep: ltep,
      metadata_size: 4096,
      unchoked?: true,
      unchoke_since: System.monotonic_time(:millisecond) - 1_000
    }

    assert {:error, reason} = Magnet.Connection.request_piece(conn, 0)
    assert reason in [:closed, :einval, :enotconn]
  end

  test "ut_metadata responses match our advertised local extension id, not the peer's" do
    peer_hs = %Handshake{m: %{"ut_metadata" => 2}, metadata_size: 60498}
    ltep = Peer.LTEP.Session.new() |> Peer.LTEP.Session.apply_peer_handshake(peer_hs)
    assert Peer.LTEP.Session.local_extension_id(ltep, "ut_metadata") == 1
    assert Peer.LTEP.Session.peer_extension_id(ltep, "ut_metadata") == 2

    request = Magnet.UtMetadata.encode_request(0)
    data = Magnet.UtMetadata.encode_data(0, 60498, :binary.copy(<<0>>, 100))
    wire = Peer.LTEP.extended_message_wire(1, data)

    assert <<20, 1, ^data::binary>> = binary_part(wire, 4, byte_size(wire) - 4)
    refute match?(<<20, 2, _::binary>>, binary_part(wire, 4, byte_size(wire) - 4))
    assert request == "d8:msg_typei0e5:piecei0ee"
  end
end

defmodule Acceptor.Connection.HandshakesTest do
  use ExUnit.Case, async: false

  test "recv does not crash when controlling_process gets badarg on closed socket" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
    {:ok, port} = :inet.port(listen)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.close(socket)
    :gen_tcp.close(listen)

    assert :ok = Acceptor.Connection.Handshakes.recv(socket)
    Process.sleep(50)
  end
end

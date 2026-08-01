defmodule Magnet.ConnectionTest.WireIds do
  @moduledoc false
  # `use Peer.Const` injects the ids as the single byte they occupy on the wire.
  # Read them back out so the test can compare that byte form against the integer
  # accessors Magnet.Connection consumes.
  use Peer.Const

  def choke, do: @choke_id
  def unchoke, do: @unchoke_id
  def interested, do: @interested_id
end

defmodule Magnet.ConnectionTest do
  use ExUnit.Case, async: false

  alias Magnet.ConnectionTest.WireIds
  alias Peer.LTEP.{Handshake, Session}

  @timeout 5_000
  # A drain that acts on the unchoke id sends its BEP 9 request the moment the frame
  # lands. A drain that does not recognise the id only sends after @unchoke_wait_ms
  # expires (BEP 9 lets us request while choked), so requiring the request well inside
  # that window is what distinguishes the two.
  @unchoke_wait_ms 3_000
  @unchoke_proof_ms 1_000

  test "request_piece returns error on closed socket without crashing" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
    {:ok, port} = :inet.port(listen)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.close(socket)
    :gen_tcp.close(listen)

    peer_hs = %Handshake{m: %{"ut_metadata" => 1}, metadata_size: 4096}
    ltep = Session.new() |> Session.apply_peer_handshake(peer_hs)

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
    peer_hs = %Handshake{m: %{"ut_metadata" => 2}, metadata_size: 60_498}
    ltep = Session.new() |> Session.apply_peer_handshake(peer_hs)
    assert Session.local_extension_id(ltep, "ut_metadata") == 1
    assert Session.peer_extension_id(ltep, "ut_metadata") == 2

    request = Magnet.UtMetadata.encode_request(0)
    data = Magnet.UtMetadata.encode_data(0, 60_498, :binary.copy(<<0>>, 100))
    wire = Peer.LTEP.extended_message_wire(1, data)

    assert <<20, 1, ^data::binary>> = binary_part(wire, 4, byte_size(wire) - 4)
    refute match?(<<20, 2, _::binary>>, binary_part(wire, 4, byte_size(wire) - 4))
    assert request == "d8:msg_typei0e5:piecei0ee"
  end

  test "Peer.Const exposes the same BEP 3 ids as a wire byte and as an integer" do
    # Magnet.Connection matches decoded id *numbers*, Peer.Sender matches on-wire
    # *bytes*. Both come from Peer.Const now, so guard the two shapes against drift.
    assert WireIds.choke() == <<Peer.Const.choke_id()>>
    assert WireIds.unchoke() == <<Peer.Const.unchoke_id()>>
    assert WireIds.interested() == <<Peer.Const.interested_id()>>

    # BEP 3 § peer messages fixes these ids; they are protocol, not a local choice.
    assert Peer.Const.choke_id() == 0
    assert Peer.Const.unchoke_id() == 1
    assert Peer.Const.interested_id() == 2
  end

  test "drain loop recognises choke and unchoke frames carrying the Peer.Const ids" do
    total_size = 100
    data = :binary.copy(<<0xAB>>, total_size)

    previous = Application.get_env(:elixir_torrent, :magnet_connection, [])

    # unchoke_stable_ms: 0 removes the BEP 3 unchoke-flap settling wait, and the short
    # wait/recv timeouts make a mistyped wire id fail in seconds instead of parking on
    # the 45s production unchoke wait.
    Application.put_env(
      :elixir_torrent,
      :magnet_connection,
      Keyword.merge(previous,
        unchoke_stable_ms: 0,
        unchoke_wait_ms: @unchoke_wait_ms,
        recv_timeout_ms: @unchoke_wait_ms
      )
    )

    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])
    {:ok, server} = :gen_tcp.accept(listen, @timeout)

    peer_hs = %Handshake{m: %{"ut_metadata" => 7}, metadata_size: total_size}

    ltep =
      Session.new([Magnet.UtMetadata.Extension])
      |> Session.apply_peer_handshake(peer_hs)

    # Starts choked, so request_piece/2 has to drain the wire until the peer unchokes.
    conn = %Magnet.Connection{
      socket: client,
      ltep: ltep,
      metadata_size: total_size,
      transport: :tcp,
      unchoked?: false,
      unchoke_since: nil
    }

    task =
      Task.async(fn ->
        receive do
          {:socket, socket} -> serve_after_unchoke(socket, total_size, data)
        end
      end)

    :ok = :gen_tcp.controlling_process(server, task.pid)
    send(task.pid, {:socket, server})

    on_exit(fn ->
      Application.put_env(:elixir_torrent, :magnet_connection, previous)
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    assert {:ok, ^data, ^total_size} = Magnet.Connection.request_piece(conn, 0)
    assert :ok = Task.await(task, @timeout)
  end

  # BEP 3 § messages: <len=0001><id>. Chokes first, then unchokes, so the drain has to
  # act on both ids rather than skipping them as unknown standard frames.
  defp serve_after_unchoke(socket, total_size, data) do
    :ok = :gen_tcp.send(socket, <<1::32, Peer.Const.choke_id()>>)
    :ok = :gen_tcp.send(socket, <<1::32, Peer.Const.unchoke_id()>>)

    assert {:ok, <<length::32>>} = :gen_tcp.recv(socket, 4, @unchoke_proof_ms)
    assert {:ok, <<20, 7, payload::binary>>} = :gen_tcp.recv(socket, length, @timeout)
    assert {:ok, {:request, [piece: 0]}} = Magnet.UtMetadata.decode_message(payload)

    :gen_tcp.send(
      socket,
      Peer.LTEP.extended_message_wire(
        Magnet.UtMetadata.Extension.local_id(),
        Magnet.UtMetadata.encode_data(0, total_size, data)
      )
    )
  end
end

defmodule Acceptor.Connection.HandshakesTest do
  use ExUnit.Case, async: false

  alias Acceptor.Connection.Handshakes

  test "recv does not crash when controlling_process gets badarg on closed socket" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
    {:ok, port} = :inet.port(listen)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.close(socket)
    :gen_tcp.close(listen)

    assert :ok = Handshakes.recv(socket)
  end
end

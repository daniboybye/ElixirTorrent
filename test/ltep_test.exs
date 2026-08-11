defmodule Peer.LTEPTest do
  use ExUnit.Case, async: true

  alias Peer.Controller.State
  alias Peer.LTEP
  alias Peer.LTEP.{Handshake, Session}

  @ut_metadata Magnet.UtMetadata.Extension

  defmodule DuplicateIdA do
    @behaviour Peer.LTEP.Extension

    @impl Peer.LTEP.Extension
    @spec name() :: String.t()
    def name, do: "test_a"

    @impl Peer.LTEP.Extension
    @spec local_id() :: pos_integer()
    def local_id, do: 42
  end

  defmodule DuplicateIdB do
    @behaviour Peer.LTEP.Extension

    @impl Peer.LTEP.Extension
    @spec name() :: String.t()
    def name, do: "test_b"

    @impl Peer.LTEP.Extension
    @spec local_id() :: pos_integer()
    def local_id, do: 42
  end

  test "Extension.outbound_fields defaults to empty map without optional callback" do
    assert Peer.LTEP.Extension.outbound_fields(DuplicateIdA) == %{}
  end

  describe "extension_protocol?/1 (BEP 10 reserved bit 20)" do
    test "true when byte index 5 has 0x10 (libtorrent layout)" do
      # libtorrent: reserved[5] = 0x10, reserved[7] = 0x01 (DHT)
      assert Peer.LTEP.extension_protocol?(<<0, 0, 0, 0, 0, 0x10, 0, 1>>)
    end

    test "true when byte index 5 has multiple bits including 0x10" do
      assert Peer.LTEP.extension_protocol?(<<0, 0, 0, 0, 0, 0x11, 0, 1>>)
      assert Peer.LTEP.extension_protocol?(<<0, 0, 0, 0, 0, 0x16, 0, 5>>)
    end

    test "false when extension bit clear at byte index 5" do
      refute Peer.LTEP.extension_protocol?(<<0::64>>)
      refute Peer.LTEP.extension_protocol?(<<0, 0, 0, 0, 0, 0, 0, 5>>)
      # 0x10 at wrong byte (index 4) must not match
      refute Peer.LTEP.extension_protocol?(<<0, 0, 0, 0, 0x10, 0, 0, 0>>)
    end

    test "catch-all is false for non-eight-byte reserved values" do
      refute Peer.LTEP.extension_protocol?(<<>>)
      refute Peer.LTEP.extension_protocol?(<<0, 0, 0, 0, 0, 0x10>>)
      refute Peer.LTEP.extension_protocol?(<<0, 0, 0, 0, 0, 0x10, 0, 0, 0>>)
      refute Peer.LTEP.extension_protocol?(42)
    end

    test "Peer.reserved/0 and Magnet.Peer.reserved/0 advertise LTEP at byte index 5" do
      assert Peer.LTEP.extension_protocol?(Peer.reserved())
      assert Peer.reserved() == <<0, 0, 0, 0, 0, 0x10, 0, 0x15>>
      assert Peer.LTEP.extension_protocol?(Magnet.Peer.reserved())
      assert Magnet.Peer.reserved() == Peer.reserved()
    end
  end

  describe "Handshake.decode/1 and encode/1" do
    test "round-trips known BEP 10 keys and ignores unknown keys" do
      raw =
        Bento.encode!(%{
          "m" => %{"ut_metadata" => 2, "ut_pex" => 3},
          "p" => 6881,
          "v" => "µTorrent 1.2",
          "yourip" => <<1, 2, 3, 4>>,
          "ipv4" => <<10, 0, 0, 1>>,
          "ipv6" => :binary.copy(<<0>>, 16),
          "reqq" => 250,
          "metadata_size" => 12_345,
          "future_key" => "ignored"
        })

      assert {:ok, hs} = Handshake.decode(raw)
      assert hs.m == %{"ut_metadata" => 2, "ut_pex" => 3}
      assert hs.p == 6881
      assert hs.v == "µTorrent 1.2"
      assert hs.yourip == <<1, 2, 3, 4>>
      assert hs.ipv4 == <<10, 0, 0, 1>>
      assert byte_size(hs.ipv6) == 16
      assert hs.reqq == 250
      assert hs.metadata_size == 12_345

      roundtrip = Handshake.encode(hs) |> then(&Handshake.decode/1)
      assert {:ok, ^hs} = roundtrip
    end

    test "rejects non-dictionary payloads" do
      assert {:error, :invalid_handshake} = Handshake.decode("i42ee")
    end

    test "skips malformed m entries and invalid field types" do
      assert {:ok, hs} =
               Handshake.decode(
                 Bento.encode!(%{
                   "m" => %{"ut_metadata" => 1, "bad" => "x", "too_large" => 256},
                   "p" => -1,
                   "reqq" => 0,
                   "yourip" => <<1, 2>>
                 })
               )

      assert hs.m == %{"ut_metadata" => 1}
      assert hs.p == nil
      assert hs.reqq == nil
      assert hs.yourip == nil
    end
  end

  describe "Handshake.peer_extension_id/2 and id 0 = unsupported" do
    test "returns positive peer id or nil when missing/disabled" do
      hs = %Handshake{m: %{"ut_metadata" => 5, "ut_pex" => 0}}

      assert Handshake.peer_extension_id(hs, "ut_metadata") == 5
      assert Handshake.peer_extension_id(hs, "ut_pex") == nil
      assert Handshake.peer_extension_id(hs, "unknown") == nil
    end
  end

  describe "Handshake.merge/2 (BEP 10 re-handshake)" do
    test "m dictionary is additive and id 0 disables an extension" do
      base = %Handshake{m: %{"ut_metadata" => 1, "ut_pex" => 2}, p: 6881, v: "A"}

      incoming =
        Handshake.from_map(%{
          "m" => %{"ut_metadata" => 0, "ut_holepunch" => 4},
          "v" => "B"
        })

      merged = Handshake.merge(base, incoming)

      assert merged.m == %{"ut_pex" => 2, "ut_holepunch" => 4}
      assert merged.p == 6881
      assert merged.v == "B"
    end

    test "updates scalar fields when present in subsequent handshake" do
      base = %Handshake{metadata_size: 100, reqq: 250}

      incoming = Handshake.from_map(%{"metadata_size" => 200, "reqq" => 128})
      merged = Handshake.merge(base, incoming)

      assert merged.metadata_size == 200
      assert merged.reqq == 128
    end
  end

  describe "Session per-peer id mapping" do
    test "local ids come from registered extensions; peer ids from their handshake" do
      session = Session.new([@ut_metadata])

      assert Session.local_extension_id(session, "ut_metadata") == 1

      peer_hs =
        Handshake.from_map(%{
          "m" => %{"ut_metadata" => 7},
          "metadata_size" => 4096
        })

      session = Session.apply_peer_handshake(session, peer_hs)

      assert Session.peer_extension_id(session, "ut_metadata") == 7
      assert Session.peer_supports?(session, "ut_metadata")
      refute Session.peer_supports?(session, "ut_pex")
      assert Session.peer_handshake(session).metadata_size == 4096
    end

    test "outbound handshake includes m and client version" do
      payload = Session.new([@ut_metadata]) |> Session.outbound_handshake()

      assert {:ok, hs} = Handshake.decode(payload)
      assert hs.m == %{"ut_metadata" => 1}
      assert hs.v =~ "ElixirTorrent"
    end

    test "outbound handshake advertises our BEP 10 reqq" do
      payload = Session.new([@ut_metadata]) |> Session.outbound_handshake()

      assert {:ok, hs} = Handshake.decode(payload)
      assert hs.reqq == Session.local_reqq()
      assert hs.reqq >= 250 and hs.reqq <= 2000
    end

    test "re-handshake merges into session and can disable ut_metadata" do
      session =
        Session.new([@ut_metadata])
        |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_metadata" => 3}}))

      assert Session.peer_extension_id(session, "ut_metadata") == 3

      session =
        Session.apply_peer_handshake(
          session,
          Handshake.from_map(%{"m" => %{"ut_metadata" => 0}})
        )

      refute Session.peer_supports?(session, "ut_metadata")
      assert Session.peer_extension_id(session, "ut_metadata") == nil
    end

    test "duplicate local extension ids fail before building a handshake" do
      assert_raise ArgumentError, ~r/LTEP extension local ids must be unique/, fn ->
        Session.new([DuplicateIdA, DuplicateIdB])
      end
    end
  end

  describe "Peer.LTEP.merge_handshake/2" do
    test "ignores invalid re-handshake payloads without crashing" do
      session = Session.new([@ut_metadata])

      assert ^session = Peer.LTEP.merge_handshake(session, "not bencode")
    end
  end

  describe "live peer-path re-handshake and unknown ids" do
    test "a second id-0 message adds and disables extensions mid-session" do
      session =
        Session.new([@ut_metadata, Peer.UtHolepunch.Extension])
        |> Session.apply_peer_handshake(%Handshake{m: %{"ut_metadata" => 7}})

      state = peer_state(session)

      rehandshake =
        Bento.encode!(%{
          "m" => %{
            "ut_metadata" => 0,
            "ut_holepunch" => 9
          }
        })

      updated = State.handle_extended(state, 0, rehandshake)

      refute Session.peer_supports?(updated.ltep, "ut_metadata")
      assert Session.peer_extension_id(updated.ltep, "ut_holepunch") == 9
    end

    test "an unrecognized extension id is ignored without changing peer state" do
      state =
        Session.new([@ut_metadata])
        |> Session.apply_peer_handshake(%Handshake{m: %{"ut_metadata" => 7}})
        |> peer_state()

      assert ^state = State.handle_extended(state, 254, <<0, 1, 2, 3>>)
    end
  end

  describe "recv_extended/2 socket path (BEP 10 inbound framing)" do
    @recv_timeout 5_000

    test "returns message id 20, extended id, and payload for a valid frame" do
      {client, server, listen} = loopback_client_server()

      on_exit(fn -> close_loopback(client, server, listen) end)

      payload = "d2:id1i1ee"
      wire = Peer.LTEP.extended_message_wire(3, payload)
      assert :ok = :gen_tcp.send(server, wire)

      assert {:ok, 20, 3, ^payload} = LTEP.recv_extended(client, @recv_timeout)
    end

    test "rejects length prefix below 2 without reading a body" do
      {client, server, listen} = loopback_client_server()

      on_exit(fn -> close_loopback(client, server, listen) end)

      assert :ok = :gen_tcp.send(server, <<1::32>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(client, @recv_timeout)
    end

    test "rejects length prefix above max_message_size without reading a body" do
      {client, server, listen} = loopback_client_server()

      on_exit(fn -> close_loopback(client, server, listen) end)

      oversized = Peer.LTEP.max_message_size() + 1
      assert :ok = :gen_tcp.send(server, <<oversized::32>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(client, @recv_timeout)
    end

    test "accepts a valid extended frame with empty payload" do
      {client, server, listen} = loopback_client_server()

      on_exit(fn -> close_loopback(client, server, listen) end)

      assert :ok = :gen_tcp.send(server, <<2::32, 20, 9>>)
      assert {:ok, 20, 9, <<>>} = LTEP.recv_extended(client, @recv_timeout)
    end
  end

  describe "handshake_exchange/3" do
    test "reads past choke/bitfield before peer extension handshake" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      accept =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)

          assert {:ok, client_hs} = :gen_tcp.recv(socket, 68, 5_000)
          assert <<19, "BitTorrent protocol"::binary, _::binary>> = client_hs

          server_hs =
            [
              <<19>>,
              "BitTorrent protocol",
              Peer.reserved(),
              :binary.copy(<<1>>, 20),
              Peer.id()
            ]

          :ok = :gen_tcp.send(socket, server_hs)
          :ok = :gen_tcp.send(socket, <<0, 0, 0, 1, 0>>)

          assert {:ok, <<len::32>>} = :gen_tcp.recv(socket, 4, 5_000)
          assert {:ok, our_hs_msg} = :gen_tcp.recv(socket, len, 5_000)
          assert <<20, 0, _our_hs::binary>> = our_hs_msg

          peer_hs =
            Bento.encode!(%{
              "m" => %{"ut_metadata" => 2},
              "metadata_size" => 512,
              "v" => "test"
            })

          reply = Peer.LTEP.extended_message_wire(0, peer_hs)
          :ok = :gen_tcp.send(socket, reply)
          :gen_tcp.close(socket)
          :gen_tcp.close(listen)
          :ok
        end)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

      hash = :binary.copy(<<1>>, 20)

      assert :ok = send_bittorrent_handshake(client, hash)
      assert {:ok, server_hs} = :gen_tcp.recv(client, 68, 5_000)
      assert <<19, "BitTorrent protocol"::binary, _::binary>> = server_hs

      assert {:ok, session} =
               LTEP.handshake_exchange(client, Session.new(), timeout: 5_000)

      assert Session.peer_extension_id(session, "ut_metadata") == 2
      assert Session.peer_handshake(session).metadata_size == 512
      :gen_tcp.close(client)
      assert :ok = Task.await(accept, 5_000)
    end
  end

  defp loopback_client_server do
    {:ok, listen} = listen_loopback_raw()
    {:ok, port} = :inet.port(listen)
    spawn_loopback_acceptor(listen, self())

    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    await_loopback_accept(client, listen, 5_000)
  end

  defp listen_loopback_raw do
    :gen_tcp.listen(0, [
      :binary,
      active: false,
      packet: :raw,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ])
  end

  defp spawn_loopback_acceptor(listen, parent) do
    spawn(fn ->
      case :gen_tcp.accept(listen, 5_000) do
        {:ok, server} ->
          :ok = :gen_tcp.controlling_process(server, parent)
          send(parent, {:loopback_server, server})

        error ->
          send(parent, {:loopback_accept_error, error})
      end
    end)
  end

  defp await_loopback_accept(client, listen, timeout) do
    receive do
      {:loopback_server, server} ->
        {client, server, listen}

      {:loopback_accept_error, error} ->
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        flunk("accept failed: #{inspect(error)}")
    after
      timeout ->
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
        flunk("accept timed out")
    end
  end

  defp close_loopback(client, server, listen) do
    for sock <- [client, server, listen] do
      try do
        if is_port(sock), do: :gen_tcp.close(sock)
      catch
        :error, _ -> :ok
      end
    end
  end

  defp send_bittorrent_handshake(socket, hash) do
    :gen_tcp.send(
      socket,
      [
        <<19>>,
        "BitTorrent protocol",
        Peer.reserved(),
        hash,
        Peer.id()
      ]
    )
  end

  defp peer_state(ltep) do
    %State{
      hash: :crypto.strong_rand_bytes(20),
      id: :crypto.strong_rand_bytes(20),
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: nil,
      ltep: ltep
    }
  end

  describe "extended_message_wire/2 (BEP 10 outbound framing)" do
    test "uses message id 20, peer ut_metadata id, and correct length prefix" do
      payload = Magnet.UtMetadata.encode_request(0)
      assert payload == "d8:msg_typei0e5:piecei0ee"

      wire = Peer.LTEP.extended_message_wire(2, payload)
      assert byte_size(wire) == 4 + 1 + 1 + byte_size(payload)
      assert <<len::32, 20, 2, ^payload::binary>> = wire
      assert len == 1 + 1 + byte_size(payload)
    end

    test "send_extended uses the peer's extension id, not our local id" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(listen)

      accept =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          assert {:ok, <<len::32>>} = :gen_tcp.recv(socket, 4, 5_000)
          assert {:ok, message} = :gen_tcp.recv(socket, len, 5_000)
          :gen_tcp.close(socket)
          :gen_tcp.close(listen)
          {len, message}
        end)

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

      payload = Magnet.UtMetadata.encode_request(0)
      assert :ok = Peer.LTEP.send_extended(client, 7, payload)
      :gen_tcp.close(client)
      assert {len, message} = Task.await(accept, 5_000)
      assert <<20, 7, ^payload::binary>> = message
      assert len == 1 + 1 + byte_size(payload)
    end
  end
end

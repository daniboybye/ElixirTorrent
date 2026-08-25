defmodule PeerControllerStateTest do
  use ExUnit.Case, async: false

  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias Peer.Controller.State
  alias Peer.LTEP.{Handshake, Session}
  alias Peer.UtPex.Entry, as: UtPexEntry
  alias Peer.UtPex.Extension, as: UtPexExtension
  alias PeerWireTest.SentCollector

  @piece_len 16_384
  @timeout 2_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "first_message/2 startup branches" do
    test "seed with Fast sends have_all" do
      hash = :crypto.strong_rand_bytes(20)

      with_sender_stub(hash, fn _key ->
        state =
          base_state(hash, 4, status: :seed, fast_extension: %Peer.Controller.FastExtension{})

        assert %State{} = State.first_message(state, 0)
        assert_receive {:sent, :have_all}
      end)
    end

    test "seed without Fast sends bitfield" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4, left: 0), fn _ ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 4, status: :seed)

          assert %State{} = State.first_message(state, 0)
          assert_receive {:sent, {:bitfield, ^hash}}
        end)
      end)
    end

    test "leech with Fast at downloaded 0 sends bitfield not have_none" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          state =
            base_state(hash, 4, status: 0, fast_extension: %Peer.Controller.FastExtension{})

          assert %State{} = State.first_message(state, 0)
          assert_receive {:sent, {:bitfield, ^hash}}
          refute_received {:sent, :have_none}
        end)
      end)
    end
  end

  describe "have/2 and handle_have/2" do
    test "have/2 skips wire when we already advertise the piece" do
      hash = :crypto.strong_rand_bytes(20)
      bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 1, 1)

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, bitfield: bitfield)
        assert %State{} = State.have(state, 1)
        refute_received {:sent, _}
      end)
    end

    test "verified-piece availability suggests the piece to a Fast peer" do
      hash = :crypto.strong_rand_bytes(20)

      with_sender_stub(hash, fn _key ->
        state =
          base_state(hash, 4,
            bitfield: Torrent.Bitfield.make(4),
            fast_extension: %Peer.Controller.FastExtension{}
          )

        assert %State{} = State.have(state, 2)
        assert_receive {:sent, {:have, 2}}
        assert_receive {:sent, {:suggest_piece, 2}}
      end)
    end

    test "verified-piece availability never suggests to a non-Fast peer" do
      hash = :crypto.strong_rand_bytes(20)

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, bitfield: Torrent.Bitfield.make(4))

        assert %State{} = State.have(state, 2)
        assert_receive {:sent, {:have, 2}}
        refute_received {:sent, {:suggest_piece, 2}}
      end)
    end

    test "handle_have on nil bitfield bootstraps then sets the bit" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, bitfield: nil, status: 0)

        new_state = State.handle_have(state, 2)
        assert %State{bitfield: bf} = new_state
        assert State.has_index?(new_state, 2)
        assert bf != nil
      end)
    end

    test "handle_have on :all is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, bitfield: :all)

      assert {:error, :protocol_error, ^state} = State.handle_have(state, 0)
    end

    test "duplicate handle_have is a no-op" do
      hash = :crypto.strong_rand_bytes(20)
      bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 0, 1)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, bitfield: bitfield, status: 0)
        assert ^state = State.handle_have(state, 0)
      end)
    end
  end

  describe "handle_bitfield/2" do
    test "valid bitfield updates availability and pins a piece" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 2, 1)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, status: nil)

        assert %State{bitfield: ^bf, status: status} = State.handle_bitfield(state, bf)
        assert is_integer(status)
      end)
    end

    test "second bitfield is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.make(4)
      state = base_state(hash, 4, bitfield: bf)

      assert {:error, :protocol_error, ^state} = State.handle_bitfield(state, bf)
    end

    test "seed peer ignores inbound bitfield" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, status: :seed, bitfield: nil)
      assert ^state = State.handle_bitfield(state, Torrent.Bitfield.make(4))
    end

    test "invalid bitfield size is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4)
        assert {:error, :protocol_error, ^state} = State.handle_bitfield(state, <<0, 0>>)
      end)
    end

    test "non-zero spare bits in the final bitfield byte are protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      pieces_count = 10
      bitfield_with_spare_bit = <<0, 0b00000001>>

      with_model(sample_torrent(hash, pieces_count), fn _ ->
        state = base_state(hash, pieces_count)

        assert {:error, :protocol_error, ^state} =
                 State.handle_bitfield(state, bitfield_with_spare_bit)
      end)
    end
  end

  describe "Fast extension have_all / have_none" do
    test "handle_have_all marks peer as :all and unchokes for download" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          state =
            base_state(hash, 4,
              status: 0,
              interested: false,
              fast_extension: %Peer.Controller.FastExtension{}
            )

          assert %State{bitfield: :all, choke: false} = State.handle_have_all(state)
        end)
      end)
    end

    test "handle_have_all while seeding is two_seeders error" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          status: :seed,
          fast_extension: %Peer.Controller.FastExtension{}
        )

      assert {:error, :two_seeders, ^state} = State.handle_have_all(state)
    end

    test "negotiated have_all after initial availability is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          status: 0,
          bitfield: Torrent.Bitfield.make(4),
          fast_extension: %Peer.Controller.FastExtension{}
        )

      assert {:error, :protocol_error, ^state} = State.handle_have_all(state)
    end

    test "handle_have_none on leech sets :none" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          status: 0,
          fast_extension: %Peer.Controller.FastExtension{}
        )

      assert %State{bitfield: :none} = State.handle_have_none(state)
    end

    test "handle_have_none with existing bitfield is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          bitfield: Torrent.Bitfield.make(4),
          fast_extension: %Peer.Controller.FastExtension{}
        )

      assert {:error, :protocol_error, ^state} = State.handle_have_none(state)
    end

    test "non-negotiated have_none is still applied" do
      hash = :crypto.strong_rand_bytes(20)

      # The message needs no Fast state to be read: it says what an empty bitfield
      # says. Refusing it cost us the peer and blacklisted its id, for information
      # we could simply have used. `have_all` takes the same path but also touches
      # PiecesStatistic, so it is covered where a model is running.
      assert {:noreply, %State{bitfield: :none}} =
               Peer.Controller.handle_cast(
                 {:handle_have_none, []},
                 base_state(hash, 4, status: 0)
               )
    end
  end

  describe "BEP 6 choke request flushing" do
    test "choke rejects queued non-allowed uploads after the choke" do
      hash = :crypto.strong_rand_bytes(20)
      rejected = {0, 0, @piece_len}
      allowed = {1, 0, @piece_len}

      with_sender_stub(hash, fn _key ->
        fast = %Peer.Controller.FastExtension{allowed_fast: MapSet.new([1])}

        state =
          base_state(hash, 4,
            choke: false,
            fast_extension: fast,
            upload_requests: MapSet.new([rejected, allowed])
          )

        assert %State{choke: true, upload_requests: remaining} =
                 choked = State.choke(state)

        assert remaining == MapSet.new([allowed])
        assert_receive {:sent, :choke}
        assert_receive {:sent, {:reject, 0, 0, @piece_len}}
        refute_received {:sent, {:reject, 1, 0, @piece_len}}

        assert {:cancelled, ^choked} =
                 State.complete_upload(choked, 0, 0, @piece_len, <<0::size(8)>>)

        refute_received {:sent, {:piece, 0, 0, _}}
      end)
    end

    test "completed upload wins the mailbox race and is not also rejected" do
      hash = :crypto.strong_rand_bytes(20)
      request = {0, 0, @piece_len}
      block = <<1, 2, 3>>

      with_sender_stub(hash, fn _key ->
        state =
          base_state(hash, 4,
            choke: false,
            fast_extension: %Peer.Controller.FastExtension{},
            upload_requests: MapSet.new([request])
          )

        assert {:sent, completed} =
                 State.complete_upload(state, 0, 0, @piece_len, block)

        assert %State{choke: true, upload_requests: remaining} = State.choke(completed)
        assert MapSet.size(remaining) == 0
        assert_receive {:sent, {:piece, 0, 0, ^block}}
        assert_receive {:sent, :choke}
        refute_received {:sent, {:reject, 0, 0, @piece_len}}
      end)
    end
  end

  describe "disconnect_operations/1 and eviction helpers" do
    test "disconnect flushes cancels, not_interested, and choke" do
      hash = :crypto.strong_rand_bytes(20)

      with_sender_stub(hash, fn _key ->
        state =
          base_state(hash, 4,
            interested: true,
            choke: false,
            requests: MapSet.new([{0, 0, @piece_len}])
          )

        {ops, _state} = State.disconnect_operations(state)

        assert {:cancel, 0, 0, @piece_len} in ops
        assert :not_interested in ops
        assert :choke in ops
      end)
    end

    test "eviction_info and useful_for_download? branches" do
      hash = :crypto.strong_rand_bytes(20)
      now = System.monotonic_time(:millisecond)

      with_model(sample_torrent(hash, 4, left: 0), fn _ ->
        idle =
          base_state(hash, 4,
            bitfield: :none,
            connected_at: now - 5_000,
            last_block_at: now - 1_000
          )

        info = State.eviction_info(idle)
        assert info.downloaded_bytes == 0
        assert info.age_ms >= 5_000
        assert info.idle_ms >= 1_000
        refute info.useful?
        refute info.seeder?

        all = %{idle | bitfield: :all}
        assert State.eviction_info(all).seeder?
        refute State.useful_for_download?(all)

        interested = %{idle | bitfield: nil, interested: true}
        assert State.useful_for_download?(interested)
      end)
    end

    test "rank/1 returns tuple only when peer is interested in us" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<3::160>>

      state =
        base_state(hash, 4, id: id, rank: 42, interested_of_me: true)

      assert State.rank(state) == {42, id}
      refute State.rank(%{state | interested_of_me: false})
    end

    test "stale_useless_pin? detects choked zero-byte pins" do
      hash = :crypto.strong_rand_bytes(20)
      now = System.monotonic_time(:millisecond)

      state =
        base_state(hash, 4,
          status: 0,
          choke_me: true,
          pin_downloaded_bytes: 0,
          pinned_at: now - 25_000
        )

      assert State.stale_useless_pin?(state)
      refute State.stale_useless_pin?(%{state | pin_downloaded_bytes: 1})
    end
  end

  describe "reject, cancel, and piece accounting" do
    test "handle_reject clears matching in-flight request" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        _peer = ensure_peer_registered(hash)

        on_exit(fn -> stop_worker(piece_pid) end)

        state =
          base_state(hash, 4,
            status: 0,
            interested: true,
            choke_me: false,
            requests: MapSet.new([{0, 0, @piece_len}])
          )

        assert %State{requests: reqs} = State.handle_reject(state, 0, 0, @piece_len)
        assert MapSet.size(reqs) == 0
      end)
    end

    test "handle_reject for unknown request is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, requests: MapSet.new())

      assert {:error, :protocol_error, ^state} =
               State.handle_reject(state, 0, 0, @piece_len)
    end

    test "handle_piece without matching request is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          status: 0,
          requests: MapSet.new([{0, 0, @piece_len}])
        )

      assert {:error, :protocol_error, ^state} =
               State.handle_piece(state, 0, @piece_len, @piece_len)
    end

    test "handle_piece with matching request updates counters" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          status: 0,
          requests: MapSet.new([{0, 0, @piece_len}]),
          rank: 0,
          downloaded_bytes: 0
        )

      assert %State{
               rank: @piece_len,
               downloaded_bytes: @piece_len,
               requests: reqs
             } = State.handle_piece(state, 0, 0, @piece_len)

      assert MapSet.size(reqs) == 0
    end
  end

  describe "Fast extension suggest, allowed_fast, and send_allowed_fast" do
    test "handle_suggest_piece pins an interested index when peer has it and we lack it" do
      hash = :crypto.strong_rand_bytes(20)
      peer_bf = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 2, 1)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          state =
            base_state(hash, 4,
              bitfield: peer_bf,
              status: nil,
              interested: false,
              fast_extension: %Peer.Controller.FastExtension{}
            )

          assert %State{status: 2, interested: true} = State.handle_suggest_piece(state, 2)
          assert_receive {:sent, :interested}
        end)
      end)
    end

    test "handle_suggest_piece is protocol_error for out-of-range index" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, fast_extension: %Peer.Controller.FastExtension{})

        assert {:error, :protocol_error, ^state} = State.handle_suggest_piece(state, 99)
        assert {:error, :protocol_error, ^state} = State.handle_suggest_piece(state, -1)
      end)
    end

    test "handle_suggest_piece is a no-op during magnet bootstrap" do
      hash = :crypto.strong_rand_bytes(20)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "bootstrap-suggest"}

      :ok = Magnet.Bootstrap.ensure(magnet)
      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      state = base_state(hash, 4, fast_extension: %Peer.Controller.FastExtension{})
      assert ^state = State.handle_suggest_piece(state, 0)
    end

    test "handle_allowed_fast records allowed_fast_me and may download while choked" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        state =
          base_state(hash, 4,
            interested: true,
            status: 1,
            choke_me: true,
            fast_extension: %Peer.Controller.FastExtension{allowed_fast_me: MapSet.new()}
          )

        assert %State{fast_extension: %Peer.Controller.FastExtension{allowed_fast_me: me}} =
                 State.handle_allowed_fast(state, 1)

        assert MapSet.member?(me, 1)
        assert Torrent.PiecesStatistic.get_status(hash, 1) == :allowed_fast
      end)
    end

    test "handle_allowed_fast ignores invalid indices and bootstrap torrents" do
      hash = :crypto.strong_rand_bytes(20)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "bootstrap-allowed"}

      :ok = Magnet.Bootstrap.ensure(magnet)
      on_exit(fn -> Magnet.Bootstrap.stop(hash) end)

      state =
        base_state(hash, 4,
          fast_extension: %Peer.Controller.FastExtension{allowed_fast_me: MapSet.new()}
        )

      assert ^state = State.handle_allowed_fast(state, 99)
      assert ^state = State.handle_allowed_fast(state, -1)
    end

    test "send_allowed_fast emits allowed_fast wire ids from loopback peer address" do
      hash = :crypto.strong_rand_bytes(20)
      pieces_count = 12
      {listen, server, client} = listen_socket()

      on_exit(fn ->
        if is_port(listen), do: :gen_tcp.close(listen)
        if is_port(server), do: :gen_tcp.close(server)
        if is_port(client), do: :gen_tcp.close(client)
      end)

      with_model(sample_torrent(hash, pieces_count, left: 0), fn _ ->
        with_sender_stub(hash, fn _key ->
          fast = %Peer.Controller.FastExtension{allowed_fast: MapSet.new()}

          state =
            base_state(hash, pieces_count,
              status: :seed,
              socket: server,
              fast_extension: fast
            )

          assert %State{fast_extension: %Peer.Controller.FastExtension{allowed_fast: set}} =
                   State.send_allowed_fast(state)

          assert MapSet.size(set) > 0

          received =
            for _ <- 1..MapSet.size(set) do
              assert_receive {:sent, {:allowed_fast, idx}}, @timeout
              idx
            end

          assert MapSet.new(received) == set
        end)
      end)
    end

    test "handle_have_none on a seed sends allowed_fast once" do
      hash = :crypto.strong_rand_bytes(20)
      pieces_count = 12
      {listen, server, client} = listen_socket()

      on_exit(fn ->
        if is_port(listen), do: :gen_tcp.close(listen)
        if is_port(server), do: :gen_tcp.close(server)
        if is_port(client), do: :gen_tcp.close(client)
      end)

      with_model(sample_torrent(hash, pieces_count, left: 0), fn _ ->
        with_sender_stub(hash, fn _key ->
          state =
            base_state(hash, pieces_count,
              status: :seed,
              bitfield: nil,
              socket: server,
              fast_extension: %Peer.Controller.FastExtension{}
            )

          assert %State{bitfield: :none} = State.handle_have_none(state)
          assert_receive {:sent, {:allowed_fast, _}}, @timeout
        end)
      end)
    end
  end

  describe "DHT PORT (handle_port/2)" do
    test "valid PORT on a normal torrent seeds DHT with the loopback peer ip" do
      hash = :crypto.strong_rand_bytes(20)
      {listen, server, client} = listen_socket()
      {:ok, {peer_ip, _peer_port}} = Peer.Transport.safe_peername(server)

      on_exit(fn ->
        if is_port(listen), do: :gen_tcp.close(listen)
        if is_port(server), do: :gen_tcp.close(server)
        if is_port(client), do: :gen_tcp.close(client)
      end)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, socket: server)
        pending_before = dht_pending_count()

        assert ^state = State.handle_port(state, 6882)

        if DHT.enabled?() do
          TestSupport.Sync.sync(DHT)
          assert dht_pending_count() >= pending_before
        end

        refute Magnet.Bootstrap.active?(hash)
        assert is_tuple(peer_ip)
      end)
    end

    test "PORT is ignored during magnet bootstrap" do
      hash = :crypto.strong_rand_bytes(20)
      magnet = %Magnet{hash: hash, trackers: [], display_name: "bootstrap-port"}
      {listen, server, client} = listen_socket()

      on_exit(fn ->
        Magnet.Bootstrap.stop(hash)
        if is_port(listen), do: :gen_tcp.close(listen)
        if is_port(server), do: :gen_tcp.close(server)
        if is_port(client), do: :gen_tcp.close(client)
      end)

      :ok = Magnet.Bootstrap.ensure(magnet)

      state = base_state(hash, 4, socket: server)
      pending_before = dht_pending_count()

      assert ^state = State.handle_port(state, 6882)

      if DHT.enabled?() do
        TestSupport.Sync.sync(DHT)
        assert dht_pending_count() == pending_before
      end
    end

    test "PORT outside 1..65535 and missing socket are no-ops" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, socket: nil)
        assert ^state = State.handle_port(state, 0)
        assert ^state = State.handle_port(state, 70_000)
      end)
    end
  end

  describe "BEP 9 ut_metadata request serving in handle_extended/3" do
    test "serves metadata piece over LTEP when info_blob is available" do
      hash = :crypto.strong_rand_bytes(20)
      info_blob = Bento.encode!(%{"name" => "md-serve", "length" => 100})
      total = byte_size(info_blob)

      with_model(metadata_torrent(hash, info_blob), fn _ ->
        with_sender_stub(hash, fn _key ->
          state =
            base_state(hash, 1,
              ltep: ltep_with_ut_metadata(),
              status: :seed
            )

          request = Magnet.UtMetadata.encode_request(0)

          assert %State{} = State.handle_extended(state, ut_metadata_local_id(), request)

          assert_receive {:sent, {:socket_raw, wire}}, @timeout

          assert {:ok, {:data, [piece: 0, total_size: ^total, data: ^info_blob]}} =
                   decode_ltep(wire)
        end)
      end)
    end

    test "rejects unavailable metadata and ignores malformed ut_metadata payloads" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 4, ltep: ltep_with_ut_metadata())

          reject_req = Magnet.UtMetadata.encode_request(0)

          after_reject = State.handle_extended(state, ut_metadata_local_id(), reject_req)
          assert after_reject.ut_metadata_requests.count == 1
          assert_receive {:sent, {:socket_raw, reject_wire}}, @timeout
          assert {:ok, {:reject, [piece: 0]}} = decode_ltep(reject_wire)

          refute_received {:sent, {:socket_raw, _}}

          assert ^after_reject =
                   State.handle_extended(
                     after_reject,
                     ut_metadata_local_id(),
                     "not-a-bencode-dict"
                   )
        end)
      end)
    end

    test "rate-limited ut_metadata requests are dropped without a wire reply" do
      hash = :crypto.strong_rand_bytes(20)
      info_blob = Bento.encode!(%{"name" => "md-gate", "length" => 50})

      with_model(metadata_torrent(hash, info_blob), fn _ ->
        with_sender_stub(hash, fn _key ->
          now = System.monotonic_time(:millisecond)

          state =
            base_state(hash, 1,
              ltep: ltep_with_ut_metadata(),
              status: :seed,
              ut_metadata_requests: %{
                window_started_at: now,
                count: State.ut_metadata_request_limit()
              }
            )

          request = Magnet.UtMetadata.encode_request(0)

          assert ^state = State.handle_extended(state, ut_metadata_local_id(), request)
          refute_received {:sent, {:socket_raw, _}}
        end)
      end)
    end
  end

  describe "PEX transmit and delivery error branches" do
    test "send_pex transmits over LTEP when ut_pex is negotiated" do
      hash = :crypto.strong_rand_bytes(20)
      payload = Bento.encode!(%{"added" => <<>>})

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 4, ltep: ltep_with_ut_pex())

          assert ^state = State.send_pex(state, payload)
          assert_receive {:sent, {:socket_raw, wire}}, @timeout
          <<_len::32, 20, ext_id, rest::binary>> = IO.iodata_to_binary(wire)
          assert ext_id == ut_pex_peer_id()
          assert rest == payload
        end)
      end)
    end

    test "send_pex without LTEP leaves state unchanged" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, ltep: nil)

      assert ^state = State.send_pex(state, "pex")
      refute_received {:sent, _}
    end

    test "initial PEX apply with a failing send_fun clears initial_pending?" do
      hash = :crypto.strong_rand_bytes(20)
      ep = {{1, 2, 3, 4}, 6881}
      current = %{ep => UtPexEntry.new(ep)}

      state =
        base_state(hash, 4,
          ltep: ltep_with_ut_pex(),
          pex_outbound: %{initial_sent?: false, initial_pending?: true, sent: %{}}
        )

      after_state =
        State.apply_pex_snapshot(state, current, send_fun: fn _ -> :error end)

      refute after_state.pex_outbound.initial_pending?
      refute after_state.pex_outbound.initial_sent?
      assert after_state.pex_outbound.sent == %{}
    end

    test "delta PEX apply with a failing send_fun leaves sent map unchanged" do
      hash = :crypto.strong_rand_bytes(20)
      ep = {{1, 2, 3, 5}, 6882}
      current = %{ep => UtPexEntry.new(ep)}

      state =
        base_state(hash, 4,
          ltep: ltep_with_ut_pex(),
          pex_outbound: %{initial_sent?: true, initial_pending?: false, sent: %{}}
        )

      after_state =
        State.apply_pex_snapshot(state, current, send_fun: fn _ -> :error end)

      assert after_state.pex_outbound.sent == %{}
    end
  end

  describe "completed seed transition and verified have/suggest" do
    test "seed transition on a Fast peer sends allowed_fast after have batch" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<6::160>>
      pieces_count = 12
      {listen, server, client} = listen_socket()

      on_exit(fn ->
        if is_port(listen), do: :gen_tcp.close(listen)
        if is_port(server), do: :gen_tcp.close(server)
        if is_port(client), do: :gen_tcp.close(client)
      end)

      with_model(sample_torrent(hash, pieces_count, left: 0, peer_status: :seed), fn _ ->
        with_sender_stub(hash, id, fn _key ->
          state =
            base_state(hash, pieces_count,
              id: id,
              status: 0,
              interested: true,
              bitfield: Torrent.Bitfield.make(pieces_count),
              socket: server,
              fast_extension: %Peer.Controller.FastExtension{}
            )

          assert %State{status: :seed, interested: false} = State.seed(state)
          assert_receive {:sent, :not_interested}, @timeout

          for index <- 0..(pieces_count - 1) do
            assert_receive {:sent, {:have, ^index}}, @timeout
          end

          assert_receive {:sent, {:allowed_fast, _}}, @timeout
          refute_received {:sent, :have_all}
        end)
      end)
    end

    test "have/2 on a verified piece suggests it to Fast peers" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        :ok = Torrent.PiecesStatistic.set(hash, 3, :complete)

        with_sender_stub(hash, fn _key ->
          state =
            base_state(hash, 4,
              bitfield: Torrent.Bitfield.make(4),
              fast_extension: %Peer.Controller.FastExtension{}
            )

          assert %State{} = State.have(state, 3)
          assert_receive {:sent, {:have, 3}}, @timeout
          assert_receive {:sent, {:suggest_piece, 3}}, @timeout
        end)
      end)
    end
  end

  describe "BEP 6 upload request serving" do
    @block_len 4_096

    test "Fast reject when model bitfield claims piece but statistic/disk says absent" do
      hash = :crypto.strong_rand_bytes(20)

      with_tmp_dir(fn dir ->
        bitfield =
          Torrent.Bitfield.make(1)
          |> Torrent.Bitfield.set(0, 1)

        torrent =
          build_single_piece_torrent(hash, dir,
            bitfield: bitfield,
            left: 0,
            downloaded: @piece_len
          )

        with_model(torrent, fn _ ->
          refute Torrent.have?(hash, 0)

          with_sender_stub(hash, fn _key ->
            state =
              base_state(hash, 1,
                choke: false,
                status: :seed,
                fast_extension: %Peer.Controller.FastExtension{}
              )

            assert ^state = State.handle_request(state, 0, 0, @block_len)
            assert_receive {:sent, {:reject, 0, 0, @block_len}}
          end)
        end)
      end)
    end

    test "no piece on disk without Fast is a silent ignore (no reject, no protocol_error)" do
      hash = :crypto.strong_rand_bytes(20)

      with_tmp_dir(fn dir ->
        bitfield =
          Torrent.Bitfield.make(1)
          |> Torrent.Bitfield.set(0, 1)

        torrent =
          build_single_piece_torrent(hash, dir,
            bitfield: bitfield,
            left: 0,
            downloaded: @piece_len
          )

        with_model(torrent, fn _ ->
          with_sender_stub(hash, fn _key ->
            state = base_state(hash, 1, choke: false, status: :seed)

            assert ^state = State.handle_request(state, 0, 0, @block_len)
            refute_received {:sent, _}
          end)
        end)
      end)
    end

    test "choked non-allowed-fast request emits reject and never enqueues upload" do
      hash = :crypto.strong_rand_bytes(20)
      piece_data = :crypto.strong_rand_bytes(@piece_len)

      with_tmp_dir(fn dir ->
        torrent = build_single_piece_torrent(hash, dir, piece_data: piece_data)

        with_upload_stack(torrent, fn _ ->
          seed_piece_on_disk!(hash, 0, piece_data)

          with_sender_stub(hash, fn _key ->
            state =
              base_state(hash, 1,
                choke: true,
                status: :seed,
                fast_extension: %Peer.Controller.FastExtension{allowed_fast: MapSet.new()}
              )

            assert ^state = State.handle_request(state, 0, 0, @block_len)
            assert_receive {:sent, {:reject, 0, 0, @block_len}}
            refute_received {:sent, {:piece, _, _, _}}
          end)
        end)
      end)
    end

    test "choked allowed-fast request with piece on disk enqueues then serves on completion" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<7::160>>
      piece_data = :crypto.strong_rand_bytes(@piece_len)
      expected_block = binary_part(piece_data, 0, @block_len)

      with_tmp_dir(fn dir ->
        torrent = build_single_piece_torrent(hash, dir, piece_data: piece_data)

        with_upload_stack(torrent, fn _ ->
          seed_piece_on_disk!(hash, 0, piece_data)

          with_sender_stub(hash, id, fn _key ->
            fast = %Peer.Controller.FastExtension{allowed_fast: MapSet.new([0])}

            host_state =
              base_state(hash, 1,
                id: id,
                choke: true,
                status: :seed,
                fast_extension: fast
              )

            {:ok, host} = PeerControllerStateTest.UploadHost.start_link(host_state)

            on_exit(fn -> stop_quietly(host) end)

            assert %State{upload_requests: reqs} =
                     PeerControllerStateTest.UploadHost.handle_request(host, 0, 0, @block_len)

            assert MapSet.member?(reqs, {0, 0, @block_len})
            refute_received {:sent, {:reject, 0, 0, @block_len}}

            assert_receive {:sent, {:piece, 0, 0, ^expected_block}}

            assert_upload_task_done(id, hash, 0, 0, @block_len)

            assert %State{upload_requests: remaining, rank: @block_len} =
                     PeerControllerStateTest.UploadHost.get_state(host)

            assert MapSet.size(remaining) == 0
          end)
        end)
      end)
    end

    test "duplicate queued Fast request emits reject per BEP 6" do
      hash = :crypto.strong_rand_bytes(20)
      piece_data = :crypto.strong_rand_bytes(@piece_len)
      request = {0, 0, @block_len}

      with_tmp_dir(fn dir ->
        torrent = build_single_piece_torrent(hash, dir, piece_data: piece_data)

        with_upload_stack(torrent, fn _ ->
          seed_piece_on_disk!(hash, 0, piece_data)

          with_sender_stub(hash, fn _key ->
            state =
              base_state(hash, 1,
                choke: false,
                status: :seed,
                fast_extension: %Peer.Controller.FastExtension{},
                upload_requests: MapSet.new([request])
              )

            assert ^state = State.handle_request(state, 0, 0, @block_len)
            assert_receive {:sent, {:reject, 0, 0, @block_len}}
            refute_received {:sent, {:piece, _, _, _}}
          end)
        end)
      end)
    end

    test "second identical Fast request rejects while first upload is still in flight" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<9::160>>
      piece_data = :crypto.strong_rand_bytes(@piece_len)

      with_tmp_dir(fn dir ->
        torrent = build_single_piece_torrent(hash, dir, piece_data: piece_data)

        with_upload_stack(torrent, fn _ ->
          seed_piece_on_disk!(hash, 0, piece_data)

          with_sender_stub(hash, id, fn _key ->
            host_state =
              base_state(hash, 1,
                id: id,
                choke: false,
                status: :seed,
                fast_extension: %Peer.Controller.FastExtension{}
              )

            {:ok, host} = PeerControllerStateTest.UploadHost.start_link(host_state)
            on_exit(fn -> stop_quietly(host) end)

            assert %State{upload_requests: queued} =
                     PeerControllerStateTest.UploadHost.handle_request(host, 0, 0, @block_len)

            assert MapSet.member?(queued, {0, 0, @block_len})

            assert %State{upload_requests: ^queued} =
                     PeerControllerStateTest.UploadHost.handle_request(host, 0, 0, @block_len)

            assert_receive {:sent, {:reject, 0, 0, @block_len}}
          end)
        end)
      end)
    end

    test "non-Fast upload callback emits exact block and updates seed rank accounting" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<5::160>>
      piece_data = :crypto.strong_rand_bytes(@piece_len)
      expected_block = binary_part(piece_data, 0, @block_len)

      with_tmp_dir(fn dir ->
        torrent = build_single_piece_torrent(hash, dir, piece_data: piece_data)

        with_upload_stack(torrent, fn _ ->
          seed_piece_on_disk!(hash, 0, piece_data)

          with_sender_stub(hash, id, fn _key ->
            host_state =
              base_state(hash, 1,
                id: id,
                choke: false,
                status: :seed,
                fast_extension: nil,
                rank: 0
              )

            {:ok, host} = PeerControllerStateTest.UploadHost.start_link(host_state)
            on_exit(fn -> stop_quietly(host) end)

            assert %State{upload_requests: reqs} =
                     PeerControllerStateTest.UploadHost.handle_request(host, 0, 0, @block_len)

            assert MapSet.size(reqs) == 0

            assert_receive {:sent, {:piece, 0, 0, ^expected_block}}

            assert_upload_task_done(id, hash, 0, 0, @block_len)

            assert %State{rank: @block_len} = PeerControllerStateTest.UploadHost.get_state(host)
          end)
        end)
      end)
    end
  end

  describe "upload reject guards, LTEP/unchoke fallbacks, and pin selection" do
    @block_len 4_096

    test "bad index and bad bounds return protocol_error without a wire reject" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 2), fn _ ->
        with_sender_stub(hash, fn _key ->
          seed =
            base_state(hash, 2,
              choke: false,
              status: :seed,
              fast_extension: %Peer.Controller.FastExtension{}
            )

          assert {:error, :protocol_error, ^seed} = State.handle_request(seed, 99, 0, @block_len)

          assert {:error, :protocol_error, ^seed} =
                   State.handle_request(seed, 0, 0, @piece_len + 1)

          refute_received {:sent, _}
        end)
      end)
    end

    test "superseed_hidden rejects non-assigned pieces on the wire when Fast is negotiated" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<0x55::160>>
      piece_data = :crypto.strong_rand_bytes(@piece_len)

      with_tmp_dir(fn dir ->
        torrent =
          build_two_piece_torrent(hash, dir, piece_data)
          |> Map.put(:peer_status, nil)

        with_model(torrent, fn _ ->
          {:ok, superseed} = Torrent.Superseed.start_link(hash)

          on_exit(fn -> stop_quietly(superseed) end)

          {:ok, fh_pid} = Torrent.FileHandle.start_link(hash)
          on_exit(fn -> stop_quietly(fh_pid) end)

          case Task.Supervisor.start_link(
                 max_restarts: 0,
                 name: {:via, Registry, {Registry, {hash, Torrent.Uploader}}}
               ) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
          end

          seed_piece_on_disk!(hash, 0, piece_data)
          seed_piece_on_disk!(hash, 1, piece_data)

          assert :armed = Torrent.Superseed.arm(hash)
          assert :active = Torrent.Superseed.activate(hash, 0)

          leech_bf = Torrent.Bitfield.make(2)

          assert {:ok, assigned} = Torrent.Superseed.assign(hash, id, leech_bf)
          hidden = if assigned == 0, do: 1, else: 0

          with_sender_stub(hash, id, fn _key ->
            state =
              base_state(hash, 2,
                id: id,
                choke: false,
                status: :seed,
                superseed_piece: assigned,
                fast_extension: %Peer.Controller.FastExtension{}
              )

            assert ^state = State.handle_request(state, hidden, 0, @block_len)
            assert_receive {:sent, {:reject, ^hidden, 0, @block_len}}
          end)
        end)
      end)
    end

    test "unchoke on an already-unchoked peer is a no-op" do
      hash = :crypto.strong_rand_bytes(20)

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, choke: false, status: :seed)
        assert ^state = State.unchoke(state)
        refute_received {:sent, _}
      end)
    end

    test "handle_extended with ltep nil ignores all LTEP payloads" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, ltep: nil)

      assert ^state = State.handle_extended(state, 0, "d2:id1i1ee")
      assert ^state = State.handle_extended(state, 2, Magnet.UtMetadata.encode_request(0))
    end

    test "unavailable metadata with no peer ut_metadata id skips wire reject" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          # Local session knows ut_metadata, but the peer never negotiated an id.
          state = base_state(hash, 4, ltep: Session.new([UtMetadataExtension]))
          request = Magnet.UtMetadata.encode_request(0)

          assert %State{ut_metadata_requests: %{count: 1}} =
                   State.handle_extended(state, ut_metadata_local_id(), request)

          refute_received {:sent, _}
        end)
      end)
    end

    test "ensure_piece_index pins from model peer_status when status is unset" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 2, 1)

      torrent = sample_torrent(hash, 4) |> Map.put(:peer_status, 2)

      with_model(torrent, fn _ ->
        state = base_state(hash, 4, status: nil)

        assert %State{status: 2} = State.handle_bitfield(state, bf)
      end)
    end

    test "ensure_piece_index falls back to active download index when choice is empty" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 1, 1)

      with_model(sample_torrent(hash, 4), fn _ ->
        start_downloads_supervisor(hash)

        for i <- 0..3, do: :ok = Torrent.PiecesStatistic.set(hash, i, :complete)

        assert :ok =
                 Torrent.Downloads.piece(
                   hash,
                   3,
                   fn -> send(self(), :piece_done) end,
                   fn -> :ok end
                 )

        state = base_state(hash, 4, status: nil)

        assert %State{status: 3} = State.handle_bitfield(state, bf)
      end)
    end

    test "ensure_piece_index leaves status unset when no piece is choosable" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.make(4)

      with_model(sample_torrent(hash, 4, left: 4 * @piece_len), fn _ ->
        state = base_state(hash, 4, status: nil, interested: false)

        assert %State{status: nil} = State.handle_bitfield(state, bf)
      end)
    end

    test "start_ltep advertises metadata_size when the model has info_blob" do
      hash = :crypto.strong_rand_bytes(20)
      info_blob = Bento.encode!(%{"name" => "md-ltep", "length" => 128})

      with_model(metadata_torrent(hash, info_blob), fn _ ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 1, status: :seed)

          assert %State{ltep: %Session{}} = State.start_ltep(state)
          assert_receive {:sent, {:socket_raw, wire}}, @timeout

          raw = IO.iodata_to_binary(wire)
          <<_len::32, 20, 0, payload::binary>> = raw
          assert payload =~ "metadata_size"
          assert payload =~ "i30e"
        end)
      end)
    end

    test "handle_choke rejects in-flight piece downloads and clears the pipeline" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        start_downloads_supervisor(hash)

        assert :ok =
                 Torrent.Downloads.piece(
                   hash,
                   0,
                   fn -> :ok end,
                   fn -> :ok end
                 )

        state =
          base_state(hash, 4,
            status: 0,
            interested: true,
            requests: MapSet.new([{0, 0, @piece_len}])
          )

        assert %State{choke_me: true, requests: reqs, pending_requests: 0} =
                 State.handle_choke(state)

        assert MapSet.size(reqs) == 0
      end)
    end

    test "handle_unchoke refills the download pipeline after a choke" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        start_downloads_supervisor(hash)

        assert :ok =
                 Torrent.Downloads.piece(
                   hash,
                   0,
                   fn -> :ok end,
                   fn -> :ok end
                 )

        state =
          base_state(hash, 4,
            status: 0,
            interested: true,
            choke_me: true,
            pending_requests: 0
          )

        assert %State{choke_me: false} = State.handle_unchoke(state)
      end)
    end

    test "superseed_hidden without Fast is a silent ignore" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<0x66::160>>

      with_tmp_dir(fn dir ->
        torrent =
          build_two_piece_torrent(hash, dir, :crypto.strong_rand_bytes(@piece_len))
          |> Map.put(:peer_status, nil)

        with_model(torrent, fn _ ->
          {:ok, superseed} = Torrent.Superseed.start_link(hash)
          on_exit(fn -> stop_quietly(superseed) end)

          assert :armed = Torrent.Superseed.arm(hash)
          assert :active = Torrent.Superseed.activate(hash, 0)

          leech_bf = Torrent.Bitfield.make(2)
          assert {:ok, assigned} = Torrent.Superseed.assign(hash, id, leech_bf)
          hidden = if assigned == 0, do: 1, else: 0

          with_sender_stub(hash, id, fn _key ->
            state =
              base_state(hash, 2,
                id: id,
                choke: false,
                status: :seed,
                superseed_piece: assigned,
                fast_extension: nil
              )

            assert ^state = State.handle_request(state, hidden, 0, @block_len)
            refute_received {:sent, _}
          end)
        end)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count, opts \\ []) do
    left = Keyword.get(opts, :left, pieces_count * @piece_len)

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => @piece_len}},
      left: left,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(pieces_count),
      peer_status: nil
    }
  end

  defp base_state(hash, pieces_count, overrides \\ []) do
    struct!(
      %State{
        hash: hash,
        id: Peer.id(),
        fast_extension: nil,
        status: nil,
        pieces_count: pieces_count,
        socket: nil,
        choke: true
      },
      overrides
    )
  end

  defp with_model(torrent, fun) do
    case Torrent.Model.start_link(torrent) do
      {:ok, model_pid} ->
        on_exit(fn ->
          try do
            TestSupport.Sync.safe_stop(model_pid, 5_000)
          catch
            :exit, _ -> :ok
          end
        end)

      {:error, {:already_started, model_pid}} ->
        on_exit(fn ->
          try do
            TestSupport.Sync.safe_stop(model_pid, 5_000)
          catch
            :exit, _ -> :ok
          end
        end)
    end

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp with_sender_stub(hash, id, fun) when is_function(fun, 1) do
    key = Peer.make_key(hash, id)

    {:ok, stub} =
      SentCollector.start_link(key, self())

    on_exit(fn ->
      try do
        TestSupport.Sync.safe_stop(stub, 500)
      catch
        :exit, _ -> :ok
      end
    end)

    fun.(key)
  end

  defp with_sender_stub(hash, fun), do: with_sender_stub(hash, Peer.id(), fun)

  defp with_tmp_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "et_peer_upload_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    fun.(dir)
  end

  defp build_single_piece_torrent(hash, download_dir, opts) do
    piece_data = Keyword.get(opts, :piece_data, :crypto.strong_rand_bytes(@piece_len))
    pieces_hash = :crypto.hash(:sha, piece_data)

    info = %{
      "name" => "seed.bin",
      "length" => @piece_len,
      "piece length" => @piece_len,
      "pieces" => pieces_hash
    }

    bitfield = Keyword.get(opts, :bitfield, Torrent.Bitfield.set(Torrent.Bitfield.make(1), 0, 1))

    %Torrent{
      hash: hash,
      metadata: %{"info" => info},
      left: Keyword.get(opts, :left, 0),
      downloaded: Keyword.get(opts, :downloaded, @piece_len),
      last_index: 0,
      last_piece_length: @piece_len,
      bitfield: bitfield,
      download_dir: download_dir,
      peer_status: :seed
    }
  end

  defp build_two_piece_torrent(hash, download_dir, piece_data) do
    pieces_hash =
      :crypto.hash(:sha, piece_data) <> :crypto.hash(:sha, piece_data)

    info = %{
      "name" => "seed2.bin",
      "length" => 2 * @piece_len,
      "piece length" => @piece_len,
      "pieces" => pieces_hash
    }

    %Torrent{
      hash: hash,
      metadata: %{"info" => info},
      left: 0,
      downloaded: 2 * @piece_len,
      last_index: 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(2),
      download_dir: download_dir,
      peer_status: :seed
    }
  end

  defp start_downloads_supervisor(hash) do
    name = {:via, Registry, {Registry, {hash, Torrent.Downloads}}}

    case DynamicSupervisor.start_link(
           name: name,
           extra_arguments: [hash],
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp with_upload_stack(torrent, fun) do
    with_model(torrent, fn _ ->
      {:ok, fh_pid} = Torrent.FileHandle.start_link(torrent.hash)

      on_exit(fn -> stop_quietly(fh_pid) end)

      case Task.Supervisor.start_link(
             max_restarts: 0,
             name: {:via, Registry, {Registry, {torrent.hash, Torrent.Uploader}}}
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      fun.(torrent)
    end)
  end

  defp seed_piece_on_disk!(hash, index, data) do
    :ok = Torrent.FileHandle.write(hash, index, 0, data)
    :ok = Torrent.FileHandle.flush(hash, index)
    :ok = Torrent.PiecesStatistic.set(hash, index, :complete)
  end

  defp assert_upload_task_done(peer_id, hash, begin, index, length) do
    key = {begin, length, index, peer_id, hash}

    assert [{task, _}] = Registry.lookup(Registry, key)
    ref = Process.monitor(task)

    # `Registry.lookup` followed by `Process.monitor` is a TOCTOU window: an
    # upload task that already finished delivers `{:DOWN, ..., :noproc}` instead
    # of `:normal`. Both answer the question this helper asks — the task ran to
    # completion — and only an abnormal exit reason is a failure. Asserting
    # `:normal` alone made the case flaky in proportion to how slow the machine
    # is, which is exactly the wrong way round.
    assert_receive {:DOWN, ^ref, :process, ^task, reason}
    assert reason in [:normal, :noproc]
  end

  defp start_piece_worker(hash, index) do
    name = {:via, Registry, {Registry, {{index, hash}, Torrent.Downloads.Piece}}}

    GenServer.start(Torrent.Downloads.Piece, {hash, index}, name: name)
  end

  defp ensure_peer_registered(hash) do
    key = Peer.make_key(hash, Peer.id())
    via = {:via, Registry, {Registry, {key, Peer}}}

    case GenServer.whereis(via) do
      nil ->
        {:ok, pid} = PeerControllerStateTest.DummyPeer.start_link(via)
        pid

      pid ->
        pid
    end
  end

  defp stop_quietly(pid) do
    if is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
  end

  defp stop_worker(pid), do: stop_quietly(pid)

  defp listen_socket do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {ip, port}} = :inet.sockname(listen)
    {:ok, client} = :gen_tcp.connect(ip, port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listen)
    {listen, server, client}
  end

  defp ltep_with_ut_metadata do
    Session.new([UtMetadataExtension])
    |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_metadata" => 2}}))
  end

  defp ltep_with_ut_pex do
    Session.new([UtPexExtension])
    |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_pex" => 2}}))
  end

  defp ut_metadata_local_id, do: UtMetadataExtension.local_id()
  defp ut_pex_peer_id, do: 2

  defp metadata_torrent(hash, info_blob) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "md", "piece length" => @piece_len}},
      info_blob: info_blob,
      left: 0,
      downloaded: @piece_len,
      last_index: 0,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.set(Torrent.Bitfield.make(1), 0, 1),
      peer_status: :seed
    }
  end

  defp decode_ltep(wire) do
    <<_len::32, 20, _ext_id, payload::binary>> = IO.iodata_to_binary(wire)
    Magnet.UtMetadata.decode_message(payload)
  end

  defp dht_pending_count do
    case Process.whereis(DHT) do
      nil -> 0
      pid -> map_size(:sys.get_state(pid).pending)
    end
  end
end

defmodule PeerControllerStateTest.UploadHost do
  @moduledoc false
  use GenServer

  alias Peer.Controller.State

  @spec start_link(State.t()) :: GenServer.on_start()
  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  @spec handle_request(pid(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          State.t() | {:error, :protocol_error, State.t()}
  def handle_request(pid, index, begin, length) do
    GenServer.call(pid, {:run, :handle_request, [index, begin, length]}, 10_000)
  end

  @spec get_state(pid()) :: State.t()
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_call({:run, fun, args}, _from, state) do
    case apply(State, fun, [state | args]) do
      {:error, _, new_state} = err ->
        {:reply, err, new_state}

      new_state ->
        {:reply, new_state, new_state}
    end
  end

  @impl GenServer
  def handle_call({:complete_upload, index, begin, length, block}, _from, state) do
    {reply, new_state} = State.complete_upload(state, index, begin, length, block)
    {:reply, reply, new_state}
  end

  @impl GenServer
  def handle_cast({:upload, [n]}, state) do
    {:noreply, State.upload(state, n)}
  end
end

defmodule PeerControllerStateTest.DummyPeer do
  @moduledoc false
  use GenServer

  @spec start_link(GenServer.name()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl GenServer
  def init(_), do: {:ok, nil}
end

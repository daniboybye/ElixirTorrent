defmodule Peer.UtPexTest do
  use ExUnit.Case, async: true

  alias Peer.UtPex

  defp start_private_model(hash) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"private" => 1, "name" => "private-pex"}},
      left: 1,
      last_index: 0,
      last_piece_length: 1,
      private?: true
    }

    start_supervised!({Torrent.Model, torrent})
  end

  test "encode/decode IPv4 peer delta" do
    added = [{{1, 2, 3, 4}, 6881}, {{5, 6, 7, 8}, 51413}]
    dropped = [{{9, 9, 9, 9}, 6000}]

    payload = UtPex.encode(added, dropped)
    assert is_binary(payload)
    assert {:ok, decoded_added, decoded_dropped} = UtPex.decode(payload)

    assert Enum.map(decoded_added, &{&1.ip, &1.port}) == added
    assert Enum.map(decoded_dropped, &{&1.ip, &1.port}) == dropped
    assert Enum.all?(decoded_added, &(&1.seed == false))
  end

  test "encode carries BEP 11 added.f bits and round-trips through Entry" do
    v4 = {{1, 2, 3, 4}, 6881}
    v6 = {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x1}, 51413}

    flags =
      Bitwise.bor(UtPex.flag_encrypted(), UtPex.flag_seed())
      |> Bitwise.bor(UtPex.flag_utp())
      |> Bitwise.bor(UtPex.flag_holepunch())
      |> Bitwise.bor(UtPex.flag_outgoing())

    added = [UtPex.Entry.new(v4, flags), UtPex.Entry.new(v6, flags)]

    assert {:ok, payload, report} = UtPex.encode_delta(added, [], initial?: false)
    assert report.added_encoded == 2
    assert report.added_truncated == 0
    assert {:ok, wire} = Bento.decode(payload)
    assert wire["added.f"] == <<flags>>
    assert wire["added6.f"] == <<flags>>

    assert {:ok, decoded, []} = UtPex.decode(payload)
    assert [p1, p2] = decoded
    assert p1 == %Peer{ip: {1, 2, 3, 4}, port: 6881, seed: true}
    assert {p2.ip, p2.port} == v6
    assert p2.seed == true
  end

  test "encode_delta caps non-initial combined v4+v6 added at 50" do
    peers =
      for i <- 1..60,
          do: UtPex.Entry.new({{10, 0, 0, rem(i, 250)}, 6000 + i}, UtPex.flag_seed())

    assert {:ok, _payload, report} = UtPex.encode_delta(peers, [], initial?: false)
    assert report.added_total == 60
    assert report.added_encoded == 50
    assert report.added_truncated == 10
    assert length(report.added_entries) == 50
  end

  test "combined cap counts IPv4 and IPv6 together" do
    v4 =
      for i <- 1..30,
          do: UtPex.Entry.new({{10, 2, 0, i}, 10_000 + i})

    v6 =
      for i <- 1..30,
          do: UtPex.Entry.new({{0x2001, 0xDB8, 0, 0, 0, 0, 0, i}, 11_000 + i})

    assert {:ok, payload, report} = UtPex.encode_delta(v4 ++ v6, [], initial?: false)
    assert report.added_encoded == 50
    assert {:ok, peers, []} = UtPex.decode(payload)
    assert Enum.count(peers, &(tuple_size(&1.ip) == 4)) == 30
    assert Enum.count(peers, &(tuple_size(&1.ip) == 8)) == 20
  end

  test "encode_delta initial added bound is defensive and exempt from 50-cap" do
    peers =
      for i <- 1..55,
          do: UtPex.Entry.new({{10, 0, 1, rem(i, 250)}, 7000 + i})

    assert {:ok, _payload, report} = UtPex.encode_delta(peers, [], initial?: true)
    assert report.initial?
    assert report.added_encoded == 55
    assert report.added_truncated == 0

    many =
      for i <- 1..210,
          do: UtPex.Entry.new({{10, 0, 2, rem(i, 250)}, 7100 + i})

    assert {:ok, _payload, big_report} = UtPex.encode_delta(many, [], initial?: true)
    assert big_report.added_encoded == 200
    assert big_report.added_truncated == 10
  end

  test "encode_delta reports dropped truncation for non-initial messages" do
    dropped = for i <- 1..60, do: {{192, 0, 2, rem(i, 250)}, 8000 + i}

    assert {:ok, _payload, report} = UtPex.encode_delta([], dropped, initial?: false)
    assert report.dropped_encoded == 50
    assert report.dropped_truncated == 10
    assert length(report.dropped_endpoints) == 50
  end

  test "non-initial message permits 50 added and 50 dropped independently" do
    added = for i <- 1..50, do: {{198, 18, 0, i}, 13_000 + i}
    dropped = for i <- 1..50, do: {{203, 0, 113, i}, 14_000 + i}

    assert {:ok, payload, report} = UtPex.encode_delta(added, dropped, initial?: false)
    assert report.added_encoded == 50
    assert report.dropped_encoded == 50
    assert {:ok, decoded_added, decoded_dropped} = UtPex.decode(payload)
    assert length(decoded_added) == 50
    assert length(decoded_dropped) == 50
  end

  test "inbound initial status is connection state, not inferred from missing drops" do
    compact =
      for i <- 1..51,
          into: <<>>,
          do: <<10, 1, 0, i, 6000 + i::16>>

    payload = Bento.encode!(%{"added" => compact})

    assert :error = UtPex.decode(payload)
    assert {:ok, peers, []} = UtPex.decode(payload, initial?: true)
    assert length(peers) == 51
  end

  test "decode rejects malformed compact lengths and wrong flag field types" do
    bad_len = Bento.encode!(%{"added" => <<1, 2, 3, 4, 0x1A>>})
    assert :error = UtPex.decode(bad_len)

    bad_flags = Bento.encode!(%{"added" => <<1, 2, 3, 4, 0x1A, 0xE1>>, "added.f" => 0})
    assert :error = UtPex.decode(bad_flags)

    bad_flags_len =
      Bento.encode!(%{
        "added" => <<1, 2, 3, 4, 0x1A, 0xE1, 5, 6, 7, 8, 0x50, 0x0C>>,
        "added.f" => <<0x02>>
      })

    assert :error = UtPex.decode(bad_flags_len)

    assert :error = UtPex.decode(Bento.encode!(%{"added6" => <<0::128, 80::8>>}))
  end

  test "decode rejects duplicate endpoints and add/drop conflicts" do
    dup =
      Bento.encode!(%{
        "added" => <<1, 2, 3, 4, 0x1A, 0xE1, 1, 2, 3, 4, 0x1A, 0xE1>>
      })

    assert :error = UtPex.decode(dup)

    conflict =
      Bento.encode!(%{
        "added" => <<1, 2, 3, 4, 0x1A, 0xE1>>,
        "dropped" => <<1, 2, 3, 4, 0x1A, 0xE1>>
      })

    assert :error = UtPex.decode(conflict)
  end

  test "decode rejects empty added key without contacts" do
    assert :error = UtPex.decode(Bento.encode!(%{"added" => <<>>}))
    assert :error = UtPex.decode(Bento.encode!(%{"foo" => "bar"}))
  end

  test "decode rejects oversize non-initial added peer counts" do
    # 51 IPv4 peers in one added blob exceeds the 50-cap validation.
    compact =
      for i <- 1..51,
          into: <<>>,
          do: <<10, 0, 0, rem(i, 250), 6000 + i::16>>

    assert :error =
             UtPex.decode(
               Bento.encode!(%{
                 "added" => compact,
                 "dropped" => <<9, 9, 9, 9, 0x17, 0x70>>
               })
             )
  end

  test "entry_from_connection maps LTEP e and outbound origin to flags" do
    ltep =
      Peer.LTEP.Session.new([])
      |> Peer.LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{e: 1})

    base = %Peer.Controller.State{
      hash: <<0::160>>,
      id: <<1::160>>,
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: nil,
      ltep: ltep,
      bitfield: :all,
      connection_origin: :outbound
    }

    entry = UtPex.entry_from_connection(base, {203, 0, 113, 1}, 6881)

    assert Bitwise.band(entry.flags, UtPex.flag_encrypted()) != 0
    assert Bitwise.band(entry.flags, UtPex.flag_seed()) != 0
    assert Bitwise.band(entry.flags, UtPex.flag_outgoing()) != 0
  end

  test "entry_from_connection derives uTP, holepunch and MSE flags from the peer" do
    ltep =
      Peer.LTEP.Session.new([])
      |> Peer.LTEP.Session.apply_peer_handshake(%Peer.LTEP.Handshake{
        m: %{Peer.UtHolepunch.extension_name() => 7}
      })

    state = %Peer.Controller.State{
      hash: <<0::160>>,
      id: <<4::160>>,
      fast_extension: nil,
      status: :seed,
      pieces_count: 1,
      socket: {:utp, self()},
      ltep: ltep,
      bitfield: :none
    }

    entry = UtPex.entry_from_connection(state, {203, 0, 113, 2}, 6881)
    assert Bitwise.band(entry.flags, UtPex.flag_utp()) != 0
    assert Bitwise.band(entry.flags, UtPex.flag_holepunch()) != 0
    assert Bitwise.band(entry.flags, UtPex.flag_seed()) == 0

    mse_entry =
      UtPex.entry_from_connection(
        %{state | socket: {:mse, nil, %{recv: nil, send: nil}}, ltep: Peer.LTEP.Session.new([])},
        {203, 0, 113, 3},
        6881
      )

    assert Bitwise.band(mse_entry.flags, UtPex.flag_encrypted()) != 0
  end

  test "oversize inbound payload does not crash decode" do
    huge = :binary.copy(<<0>>, 17_000)
    assert :error = UtPex.decode(huge)
  end

  test "decode ignores unknown keys" do
    raw =
      Bento.encode!(%{
        "added" => <<1, 2, 3, 4, 0x1A, 0xE1>>,
        "added.f" => <<0>>,
        "foo" => "bar"
      })

    assert {:ok, [%Peer{ip: {1, 2, 3, 4}, port: 6881, seed: false}], []} = UtPex.decode(raw)
  end

  test "decode marks BEP 11 seed flag (0x02) on added peers" do
    raw =
      Bento.encode!(%{
        "added" => <<1, 2, 3, 4, 0x1A, 0xE1, 5, 6, 7, 8, 0x50, 0x0C>>,
        "added.f" => <<0x02, 0x00>>
      })

    assert {:ok, peers, []} = UtPex.decode(raw)
    assert length(peers) == 2

    assert [
             %Peer{ip: {1, 2, 3, 4}, port: 6881, seed: true},
             %Peer{ip: {5, 6, 7, 8}, port: 20_492, seed: false}
           ] = peers
  end

  test "decode leaves seed nil when added.f is absent" do
    raw = Bento.encode!(%{"added" => <<1, 2, 3, 4, 0x1A, 0xE1>>})

    assert {:ok, [%Peer{ip: {1, 2, 3, 4}, port: 6881, seed: nil}], []} = UtPex.decode(raw)
  end

  test "prioritize_seed_peers dials BEP 11 seed-flagged peers first" do
    peers = [
      %Peer{ip: {1, 1, 1, 1}, port: 6881, seed: false},
      %Peer{ip: {2, 2, 2, 2}, port: 6882, seed: true},
      %Peer{ip: {3, 3, 3, 3}, port: 6883, seed: nil},
      %Peer{ip: {4, 4, 4, 4}, port: 6884, seed: true}
    ]

    assert [%Peer{seed: true}, %Peer{seed: true}, %Peer{seed: false}, %Peer{seed: nil}] =
             UtPex.prioritize_seed_peers(peers)
  end

  test "controller state tracks each relay's current PEX endpoints" do
    hash = :crypto.strong_rand_bytes(20)
    endpoint = {{10, 0, 0, 50}, 6881}

    ltep = Peer.LTEP.Session.new([Peer.UtPex.Extension])

    state = %Peer.Controller.State{
      hash: hash,
      id: <<1::160>>,
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: nil,
      ltep: ltep
    }

    added_state =
      Peer.Controller.State.handle_extended(
        state,
        Peer.UtPex.Extension.local_id(),
        UtPex.encode([endpoint], [])
      )

    assert MapSet.member?(added_state.holepunch.pex_endpoints, endpoint)

    dropped_state =
      Peer.Controller.State.handle_extended(
        added_state,
        Peer.UtPex.Extension.local_id(),
        UtPex.encode([], [endpoint])
      )

    refute MapSet.member?(dropped_state.holepunch.pex_endpoints, endpoint)
  end

  test "controller grants the larger bound only to the first inbound PEX message" do
    hash = :crypto.strong_rand_bytes(20)

    compact =
      for i <- 1..51,
          into: <<>>,
          do: <<100, 64, 0, i, 12_000 + i::16>>

    payload = Bento.encode!(%{"added" => compact})
    ltep = Peer.LTEP.Session.new([Peer.UtPex.Extension])

    state = %Peer.Controller.State{
      hash: hash,
      id: <<3::160>>,
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: nil,
      ltep: ltep
    }

    after_initial =
      Peer.Controller.State.handle_extended(state, Peer.UtPex.Extension.local_id(), payload)

    assert MapSet.size(after_initial.holepunch.pex_endpoints) == 51
    refute after_initial.pex_inbound.initial?

    after_delta =
      Peer.Controller.State.handle_extended(
        after_initial,
        Peer.UtPex.Extension.local_id(),
        payload
      )

    assert after_delta.holepunch.pex_endpoints == after_initial.holepunch.pex_endpoints
    refute after_delta.pex_inbound.initial?
  end

  test "private torrents neither advertise nor route ut_pex" do
    hash = :crypto.strong_rand_bytes(20)
    _model = start_private_model(hash)
    endpoint = {{10, 0, 0, 50}, 6881}

    refute Peer.UtPex.Extension in Peer.LTEP.Extensions.for_peer(hash)
    assert :error = UtPex.ingest(hash, UtPex.encode([endpoint], []))

    ltep = Peer.LTEP.Session.new([Peer.UtPex.Extension])

    state = %Peer.Controller.State{
      hash: hash,
      id: <<2::160>>,
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: nil,
      ltep: ltep
    }

    routed =
      Peer.Controller.State.handle_extended(
        state,
        Peer.UtPex.Extension.local_id(),
        UtPex.encode([endpoint], [])
      )

    assert routed.holepunch.pex_endpoints == MapSet.new()
    assert routed.pex_outbound.sent == %{}
  end

  describe "outbound per-connection (BEP 11 item 4)" do
    defp ltep_with_peer_pex do
      Peer.LTEP.Session.new([Peer.UtPex.Extension])
      |> Peer.LTEP.merge_handshake(
        Bento.encode!(%{"m" => %{"ut_pex" => Peer.UtPex.Extension.local_id()}})
      )
    end

    defp outbound_state(opts) do
      hash = Keyword.get(opts, :hash, :crypto.strong_rand_bytes(20))
      socket = Keyword.get(opts, :socket)
      initial_sent? = Keyword.get(opts, :initial_sent?, false)
      sent = Keyword.get(opts, :sent, %{})

      ltep = Keyword.get(opts, :ltep, ltep_with_peer_pex())

      %Peer.Controller.State{
        hash: hash,
        id: <<9::160>>,
        fast_extension: nil,
        status: nil,
        pieces_count: 1,
        socket: socket,
        ltep: ltep,
        pex_outbound: %{initial_sent?: initial_sent?, initial_pending?: false, sent: sent}
      }
    end

    defp apply_snapshot(state, current) do
      Peer.Controller.State.apply_pex_snapshot(state, current, send_fun: fn _payload -> :ok end)
    end

    defp listen_socket do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {ip, port}} = :inet.sockname(listen)
      {listen, {ip, port}}
    end

    test "initial snapshot on first apply without prior announce churn" do
      current =
        for i <- 1..3, into: %{} do
          ep = {{10, 0, 0, i}, 6000 + i}
          {ep, UtPex.Entry.new(ep)}
        end

      state = outbound_state(initial_sent?: false)
      after_state = apply_snapshot(state, current)

      assert after_state.pex_outbound.initial_sent?
      assert map_size(after_state.pex_outbound.sent) == 3
    end

    test "excludes the relay's own socket endpoint from outbound snapshots" do
      {listen, {ip, port}} = listen_socket()
      {:ok, client} = :gen_tcp.connect(ip, port, [:binary, active: false])
      {:ok, server} = :gen_tcp.accept(listen)

      on_exit(fn ->
        if is_port(listen), do: :gen_tcp.close(listen)
        if is_port(client), do: :gen_tcp.close(client)
        if is_port(server), do: :gen_tcp.close(server)
      end)

      {:ok, self_ep} = Peer.Transport.safe_peername(server)
      other_ep = {{10, 0, 0, 99}, 6999}

      current = %{
        self_ep => UtPex.Entry.new(self_ep),
        other_ep => UtPex.Entry.new(other_ep)
      }

      state = outbound_state(socket: server, initial_sent?: false)
      after_state = apply_snapshot(state, current)

      refute Map.has_key?(after_state.pex_outbound.sent, self_ep)
      assert Map.has_key?(after_state.pex_outbound.sent, other_ep)
    end

    test "each connection keeps independent sent maps" do
      ep_a = {{10, 0, 0, 1}, 7001}
      ep_b = {{10, 0, 0, 2}, 7002}
      ep_c = {{10, 0, 0, 3}, 7003}

      current = %{
        ep_a => UtPex.Entry.new(ep_a),
        ep_b => UtPex.Entry.new(ep_b),
        ep_c => UtPex.Entry.new(ep_c)
      }

      state1 = outbound_state(initial_sent?: true, sent: %{ep_a => UtPex.Entry.new(ep_a)})
      state2 = outbound_state(initial_sent?: true, sent: %{})

      after1 = apply_snapshot(state1, current)
      after2 = apply_snapshot(state2, current)

      assert map_size(after1.pex_outbound.sent) == 3
      assert map_size(after2.pex_outbound.sent) == 3
      refute state1.pex_outbound.sent == state2.pex_outbound.sent
    end

    test "unchanged snapshot tick does not advance sent state" do
      ep = {{10, 0, 0, 8}, 7008}
      current = %{ep => UtPex.Entry.new(ep)}

      state =
        outbound_state(
          initial_sent?: true,
          sent: %{ep => UtPex.Entry.new(ep)}
        )

      after_state = apply_snapshot(state, current)
      assert after_state.pex_outbound.sent == state.pex_outbound.sent
    end

    test "non-initial deltas spill past 50 added peers across ticks" do
      sent =
        for i <- 1..50, into: %{} do
          ep = {{10, 1, 0, i}, 8000 + i}
          {ep, UtPex.Entry.new(ep)}
        end

      current =
        Map.merge(
          sent,
          for i <- 51..105, into: %{} do
            ep = {{10, 2, 0, i}, 8100 + i}
            {ep, UtPex.Entry.new(ep)}
          end
        )

      state = outbound_state(initial_sent?: true, sent: sent)
      after1 = apply_snapshot(state, current)
      assert map_size(after1.pex_outbound.sent) == 100

      after2 = apply_snapshot(after1, current)
      assert map_size(after2.pex_outbound.sent) == 105

      after3 = apply_snapshot(after2, current)
      assert after3.pex_outbound.sent == after2.pex_outbound.sent
    end

    test "re-handshake with ut_pex sends initial once" do
      state = outbound_state(initial_sent?: false)
      payload = Bento.encode!(%{"m" => %{"ut_pex" => Peer.UtPex.Extension.local_id()}})

      merged = Peer.Controller.State.handle_extended(state, 0, payload)
      assert Peer.Controller.State.pex_initial_needed?(merged)

      pending = Peer.Controller.State.mark_pex_initial_pending(merged)
      refute Peer.Controller.State.pex_initial_needed?(pending)

      once = apply_snapshot(pending, %{})
      assert once.pex_outbound.initial_sent?

      twice = Peer.Controller.State.handle_extended(once, 0, payload)
      assert twice.pex_outbound.initial_sent?
      assert twice.pex_outbound.sent == once.pex_outbound.sent
      refute Peer.Controller.State.pex_initial_needed?(twice)
    end

    test "private torrents stay silent on outbound apply" do
      hash = :crypto.strong_rand_bytes(20)
      _model = start_private_model(hash)
      ep = {{10, 0, 0, 50}, 6881}
      current = %{ep => UtPex.Entry.new(ep)}

      state = outbound_state(hash: hash, initial_sent?: false)
      after_state = apply_snapshot(state, current)

      refute after_state.pex_outbound.initial_sent?
      assert after_state.pex_outbound.sent == %{}
    end

    test "failed wire send does not advance per-connection sent state" do
      ep = {{10, 0, 0, 7}, 7007}
      current = %{ep => UtPex.Entry.new(ep)}
      state = outbound_state(initial_sent?: true, sent: %{})

      routed = Peer.Controller.State.apply_pex_snapshot(state, current)

      assert routed.pex_outbound.sent == %{}
    end
  end

  describe "source-aware ingest (PEX item 5)" do
    alias Peer.ConnectionManager.Queue, as: DialQueue

    defp start_manager(hash) do
      name = {:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}
      {:ok, pid} = GenServer.start_link(Peer.ConnectionManager, hash, name: name)
      pid
    end

    test "ingest with pex_source tags offers and applies scoped drops" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_manager(hash)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)

      supplier = <<6::160>>
      keep = {{10, 0, 0, 10}, 7010}
      drop = {{10, 0, 0, 11}, 7011}

      :ok =
        Peer.ConnectionManager.offer_peers(hash, [%Peer{ip: elem(drop, 0), port: elem(drop, 1)}])

      payload = UtPex.encode([keep], [drop])

      assert {:ok, _, _} =
               UtPex.ingest(hash, payload, pex_source: supplier, initial?: false)

      state = :sys.get_state(pid)
      assert DialQueue.get_peer(state.queue, keep) != nil
      assert DialQueue.get_peer(state.queue, drop) != nil
    end

    test "ingest without pex_source still uses discovery offer path" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_manager(hash)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)

      ep = {{10, 0, 0, 12}, 7012}
      assert {:ok, _, _} = UtPex.ingest(hash, UtPex.encode([ep], []))

      state = :sys.get_state(pid)
      entry = Map.fetch!(state.queue, ep)
      assert MapSet.member?(entry.sources, :discovery)
    end

    test "one PEX delta revokes old source-owned contacts before offering new ones" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_manager(hash)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)

      supplier = <<7::160>>
      old = {{10, 0, 0, 13}, 7013}
      new = {{10, 0, 0, 14}, 7014}

      :ok =
        Peer.ConnectionManager.offer_peers_from_pex(hash, supplier, [
          %Peer{ip: elem(old, 0), port: elem(old, 1)}
        ])

      assert {:ok, _, _} =
               UtPex.ingest(hash, UtPex.encode([new], [old]), pex_source: supplier)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.queue, old)
      assert DialQueue.get_peer(state.queue, new) != nil
    end

    test "controller uses its remote peer id as the PEX ownership source" do
      hash = :crypto.strong_rand_bytes(20)
      pid = start_manager(hash)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)

      supplier = <<8::160>>
      endpoint = {{10, 0, 0, 15}, 7015}

      state = %Peer.Controller.State{
        hash: hash,
        id: supplier,
        fast_extension: nil,
        status: nil,
        pieces_count: 1,
        socket: nil,
        ltep: Peer.LTEP.Session.new([Peer.UtPex.Extension])
      }

      routed =
        Peer.Controller.State.handle_extended(
          state,
          Peer.UtPex.Extension.local_id(),
          UtPex.encode([endpoint], [])
        )

      manager_state = :sys.get_state(pid)
      entry = Map.fetch!(manager_state.queue, endpoint)
      assert MapSet.member?(entry.sources, {:pex, supplier})
      assert MapSet.member?(routed.holepunch.pex_endpoints, endpoint)
    end
  end
end

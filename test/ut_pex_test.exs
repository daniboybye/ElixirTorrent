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
  end
end

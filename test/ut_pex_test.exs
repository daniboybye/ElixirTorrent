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

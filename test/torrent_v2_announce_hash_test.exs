defmodule Torrent.V2AnnounceHashTest do
  use ExUnit.Case, async: true

  alias DHT.KRPC

  @v1 :binary.copy(<<0x11>>, 20)
  @v2 :binary.copy(<<0x22>>, 32)
  @node_id :binary.copy(<<0x33>>, 20)

  test "selects the BEP 52 swarm identifier for every torrent kind" do
    assert Torrent.select_announce_hash(:v1, @v1, nil) == {:ok, @v1}
    assert Torrent.select_announce_hash(:v1, @v1, @v2) == {:ok, @v1}
    assert Torrent.select_announce_hash(:hybrid, @v1, nil) == {:ok, @v1}
    assert Torrent.select_announce_hash(:hybrid, @v1, @v2) == {:ok, @v1}
    assert Torrent.select_announce_hash(:v2, nil, @v2) == {:ok, binary_part(@v2, 0, 20)}
    assert Torrent.select_announce_hash(:v2, @v1, @v2) == {:ok, binary_part(@v2, 0, 20)}
  end

  test "rejects kinds without their required info-hash" do
    assert Torrent.select_announce_hash(:v1, nil, nil) == {:error, :missing_v1_hash}
    assert Torrent.select_announce_hash(:hybrid, nil, @v2) == {:error, :missing_v1_hash}
    assert Torrent.select_announce_hash(:v2, @v1, nil) == {:error, :missing_v2_hash}
  end

  test "the selected pure-v2 hash reaches tracker and DHT wire encoders unchanged" do
    {:ok, hash} = Torrent.select_announce_hash(:v2, nil, @v2)

    query = Tracker.build_http_announce_query(hash, 0, 0, 1, Torrent.started())
    assert query["info_hash"] == binary_part(@v2, 0, 20)

    packet =
      KRPC.encode_query(%{
        method: :get_peers,
        transaction_id: "v2",
        node_id: @node_id,
        info_hash: hash
      })

    assert {:ok, {:query, decoded}} = KRPC.decode(packet)
    assert decoded.info_hash == binary_part(@v2, 0, 20)
  end
end

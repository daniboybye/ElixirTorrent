defmodule MagnetMetadataPeerTest do
  use ExUnit.Case, async: true

  alias Peer.LTEP.{Handshake, Session}

  test "metadata_peer_eligible requires ut_metadata plus size or seeder" do
    peer_hs = %Handshake{m: %{"ut_metadata" => 2}, metadata_size: 4096}
    ltep = Session.new() |> Session.apply_peer_handshake(peer_hs)

    refute Magnet.Bootstrap.metadata_peer_eligible?(%{
             ltep: ltep,
             metadata_size: nil,
             seeder?: false
           })

    assert Magnet.Bootstrap.metadata_peer_eligible?(%{
             ltep: ltep,
             metadata_size: 12_345,
             seeder?: false
           })

    assert Magnet.Bootstrap.metadata_peer_eligible?(%{
             ltep: ltep,
             metadata_size: nil,
             seeder?: true
           })
  end

  test "metadata_peer_candidate accepts ut_metadata before metadata_size is known" do
    peer_hs = %Handshake{m: %{"ut_metadata" => 2}, metadata_size: nil}
    ltep = Session.new() |> Session.apply_peer_handshake(peer_hs)

    assert Magnet.Bootstrap.metadata_peer_candidate?(%{
             ltep: ltep,
             metadata_size: nil,
             seeder?: false
           })

    refute Magnet.Bootstrap.metadata_peer_eligible?(%{
             ltep: ltep,
             metadata_size: nil,
             seeder?: false
           })
  end
end

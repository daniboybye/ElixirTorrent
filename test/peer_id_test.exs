defmodule PeerIdTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    on_exit(fn ->
      {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    end)

    :ok
  end

  test "peer ID prefix follows the Mix project version" do
    package_version = Mix.Project.config() |> Keyword.fetch!(:version)
    expected_prefix = "ET" <> String.replace(package_version, ".", "-")
    peer_id_prefix = expected_prefix <> "-"

    assert ElixirTorrent.version() == expected_prefix
    assert byte_size(Peer.id()) == 20
    assert binary_part(Peer.id(), 0, byte_size(peer_id_prefix)) == peer_id_prefix
  end

  test "a fresh application start generates a different random suffix" do
    prefix = ElixirTorrent.version() <> "-"

    :ok = Application.stop(:elixir_torrent)
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    first_suffix = suffix(Peer.id(), prefix)

    :ok = Application.stop(:elixir_torrent)
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    second_suffix = suffix(Peer.id(), prefix)

    refute first_suffix == second_suffix
  end

  defp suffix(peer_id, prefix) do
    assert byte_size(peer_id) == 20
    assert binary_part(peer_id, 0, byte_size(prefix)) == prefix
    binary_part(peer_id, byte_size(prefix), byte_size(peer_id) - byte_size(prefix))
  end
end

defmodule TorrentReceivedBytesTest do
  use ExUnit.Case, async: true

  alias Torrent.ReceivedBytes

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    hash = :crypto.strong_rand_bytes(20)
    on_exit(fn -> ReceivedBytes.delete(hash) end)
    {:ok, hash: hash}
  end

  test "adds up per info-hash and starts from zero", %{hash: hash} do
    other = :crypto.strong_rand_bytes(20)
    on_exit(fn -> ReceivedBytes.delete(other) end)

    assert ReceivedBytes.total(hash) == 0
    :ok = ReceivedBytes.add(hash, 16_384)
    :ok = ReceivedBytes.add(hash, 16_384)
    :ok = ReceivedBytes.add(other, 1)

    assert ReceivedBytes.total(hash) == 32_768
    assert ReceivedBytes.total(other) == 1
  end

  test "delete forgets the counter", %{hash: hash} do
    :ok = ReceivedBytes.add(hash, 10)
    :ok = ReceivedBytes.delete(hash)

    assert ReceivedBytes.total(hash) == 0
  end

  test "concurrent writers lose no bytes", %{hash: hash} do
    1..20
    |> Enum.map(fn _ ->
      Task.async(fn -> for _ <- 1..500, do: ReceivedBytes.add(hash, 16_384) end)
    end)
    |> Enum.each(&Task.await/1)

    assert ReceivedBytes.total(hash) == 20 * 500 * 16_384
  end
end

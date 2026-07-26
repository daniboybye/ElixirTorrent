defmodule PieceAvailabilityTest do
  use ExUnit.Case, async: false

  alias Peer.Controller.State

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  defp sample_torrent(hash, last_index) do
    %Torrent{
      hash: hash,
      metadata: %{"name" => "test"},
      left: 100_000,
      last_index: last_index,
      last_piece_length: 16_384
    }
  end

  defp with_model(hash, last_index, fun) do
    torrent = sample_torrent(hash, last_index)
    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    Process.unlink(model_pid)

    on_exit(fn -> TestSupport.Sync.safe_stop(model_pid, 5_000) end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp base_state(hash, pieces_count, overrides \\ []) do
    struct!(
      %State{
        hash: hash,
        id: Peer.id(),
        fast_extension: nil,
        status: nil,
        pieces_count: pieces_count,
        socket: nil
      },
      overrides
    )
  end

  test "have_all records full availability without FAST extension" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 8

    with_model(hash, pieces_count - 1, fn _torrent ->
      state = base_state(hash, pieces_count)

      new_state = State.handle_have_all(state)
      assert %State{bitfield: :all} = new_state
      assert State.has_index?(new_state, 3)
      assert Torrent.PiecesStatistic.availability(hash, 3) > 0
    end)
  end

  test "bitfield records per-piece availability" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 8
    bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(pieces_count), 5, 1)

    with_model(hash, pieces_count - 1, fn _torrent ->
      state = base_state(hash, pieces_count)

      new_state = State.handle_bitfield(state, bitfield)
      assert %State{bitfield: ^bitfield} = new_state
      refute State.has_index?(new_state, 0)
      assert State.has_index?(new_state, 5)
      assert Torrent.PiecesStatistic.availability(hash, 5) > 0
    end)
  end

  test "Peer.Controller accepts have_all when fast_extension is nil" do
    hash = :crypto.strong_rand_bytes(20)
    id = <<1::160>>
    key = Peer.make_key(hash, id)

    with_model(hash, 3, fn _torrent ->
      {:ok, pid} =
        GenServer.start(
          Peer.Controller,
          [hash, id, nil, Peer.reserved()],
          name: {:via, Registry, {Registry, {key, Peer.Controller}}}
        )

      on_exit(fn ->
        try do
          TestSupport.Sync.safe_stop(pid, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok = Peer.Controller.handle_have_all(key)
      TestSupport.Sync.sync(pid)

      assert Peer.Controller.has_all?(key)
      assert Peer.Controller.has_index?(key, 1)
    end)
  end

  test "bootstrap accepts oversized peer bitfield during metadata leech" do
    hash = :crypto.strong_rand_bytes(20)
    magnet = %Magnet{hash: hash, trackers: [], display_name: "metadata-stub"}

    :ok = Magnet.Bootstrap.ensure(magnet)

    on_exit(fn ->
      Magnet.Bootstrap.stop(hash)
    end)

    state = base_state(hash, 1)
    oversized = :binary.copy(<<255>>, 17)

    assert %State{bitfield: :all} = State.handle_bitfield(state, oversized)
  end

  test "bootstrap ignores peer piece requests during metadata leech" do
    hash = :crypto.strong_rand_bytes(20)
    magnet = %Magnet{hash: hash, trackers: [], display_name: "metadata-stub"}

    :ok = Magnet.Bootstrap.ensure(magnet)

    on_exit(fn ->
      Magnet.Bootstrap.stop(hash)
    end)

    state = base_state(hash, 1)

    assert %State{} = State.handle_request(state, 0, 0, 16_384)
  end
end

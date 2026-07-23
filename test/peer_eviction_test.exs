defmodule PeerEvictionTest do
  use ExUnit.Case, async: false

  alias Peer.Controller.State

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  defp sample_torrent(hash, last_index, attrs \\ []) do
    pieces_count = last_index + 1

    struct!(
      %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "test", "piece length" => 16_384}},
        left: pieces_count * 16_384,
        last_index: last_index,
        last_piece_length: 16_384,
        peer_status: nil
      },
      attrs
    )
  end

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      try do
        if Process.alive?(model_pid), do: GenServer.stop(model_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp base_state(hash, pieces_count, overrides \\ []) do
    now = System.monotonic_time(:millisecond)

    struct!(
      %State{
        hash: hash,
        id: Peer.id(),
        fast_extension: nil,
        status: nil,
        pieces_count: pieces_count,
        socket: nil,
        connected_at: now - 90_000,
        last_block_at: now - 90_000,
        downloaded_bytes: 0
      },
      overrides
    )
  end

  test "eviction_info reports age, bytes, choke, and usefulness" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 4
    torrent = sample_torrent(hash, pieces_count - 1)

    with_model(torrent, fn _ ->
      state =
        base_state(hash, pieces_count,
          bitfield: :none,
          choke_me: true,
          interested: false
        )

      info = State.eviction_info(state)

      assert info.downloaded_bytes == 0
      assert info.age_ms >= 90_000
      assert info.idle_ms >= 90_000
      assert info.choke_me?
      refute info.useful?
    end)
  end

  test "handle_piece increments downloaded_bytes" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 4
    torrent = sample_torrent(hash, pieces_count - 1)

    with_model(torrent, fn _ ->
      state =
        base_state(hash, pieces_count)
        |> then(fn st ->
          st
          |> Map.put(:requests, MapSet.new([{0, 0, 16_384}]))
          |> Map.put(:interested, true)
          |> Map.put(:status, 0)
        end)

      new_state = State.handle_piece(state, 0, 0, 16_384)

      assert new_state.downloaded_bytes == 16_384

      info = State.eviction_info(new_state)
      assert info.downloaded_bytes == 16_384
      assert info.idle_ms < 100
    end)
  end

  test "useful? is true for interested peers and false for empty bitfields" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 4
    torrent = sample_torrent(hash, pieces_count - 1)

    with_model(torrent, fn _ ->
      refute State.useful_for_download?(base_state(hash, pieces_count, bitfield: :none))

      assert State.useful_for_download?(
               base_state(hash, pieces_count, bitfield: :all, interested: false)
             )

      assert State.useful_for_download?(
               base_state(hash, pieces_count,
                 bitfield: Torrent.Bitfield.set(Torrent.Bitfield.make(pieces_count), 2, 1),
                 interested: true
               )
             )
    end)
  end

  test "Peer.Controller eviction_info reflects live state" do
    hash = :crypto.strong_rand_bytes(20)
    id = <<2::160>>
    key = Peer.make_key(hash, id)
    torrent = sample_torrent(hash, 3)

    with_model(torrent, fn _ ->
      {:ok, pid} =
        GenServer.start_link(
          Peer.Controller,
          [hash, id, nil, Peer.reserved()],
          name: {:via, Registry, {Registry, {key, Peer.Controller}}}
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
        now = System.monotonic_time(:millisecond)

        %{
          state
          | connected_at: now - 120_000,
            last_block_at: now - 120_000,
            downloaded_bytes: 0,
            bitfield: :none,
            choke_me: true
        }
      end)

      info = Peer.Controller.eviction_info(key)

      assert info.downloaded_bytes == 0
      assert info.age_ms >= 120_000
      refute info.useful?
      assert info.choke_me?
    end)
  end
end

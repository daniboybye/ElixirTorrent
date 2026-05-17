defmodule TorrentControllerSwarmCoverageBatchTest do
  use ExUnit.Case, async: false

  alias Torrent.{Bitfield, Downloads, Model, PiecesStatistic, Swarm}
  alias Torrent.Downloads.Piece

  @peer_a <<11::160>>
  @peer_b <<22::160>>
  @stale_ms 20_000
  @piece_len 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "Torrent.Swarm BEP-3 unchoke slots and upload offers" do
    test "unchoke is a no-op when the torrent has no pieces to offer" do
      hash = :crypto.strong_rand_bytes(20)

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "empty", "piece length" => @piece_len}},
        left: 2 * @piece_len,
        last_index: 1,
        last_piece_length: @piece_len,
        bitfield: Bitfield.make(2),
        peer_status: nil
      }

      with_stack(torrent, fn _ ->
        {_pid, key} =
          add_peer(hash, @peer_a,
            bitfield: Bitfield.make(2),
            interested_of_me: true,
            rank: 100
          )

        assert :ok = Swarm.unchoke(hash)
        assert controller_state(key).choke
      end)
    end

    test "unchoked_for_us_count reflects peers that unchoked us for download" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [0, 1])

      with_stack(torrent, fn _ ->
        {_a, key_a} = add_peer(hash, @peer_a, bitfield: both_pieces(2), choke_me: false)
        {_b, key_b} = add_peer(hash, @peer_b, bitfield: both_pieces(2), choke_me: true)

        assert Swarm.unchoked_for_us_count(hash) == 1
        assert controller_state(key_a).choke_me == false
        assert controller_state(key_b).choke_me == true
      end)
    end

    test "have/2 is skipped while superseed mode is active" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [0, 1])

      with_stack(torrent, fn _ ->
        {:ok, superseed} = Torrent.Superseed.start_link(hash)
        on_exit(fn -> TestSupport.Sync.safe_stop(superseed) end)

        :sys.replace_state(superseed, fn state -> %{state | phase: :active} end)
        assert Torrent.Superseed.active?(hash)

        {_pid, key} = add_peer(hash, @peer_a, bitfield: Bitfield.make(2))
        assert :ok = Swarm.have(hash, 0)
        refute Peer.Controller.has_index?(key, 0)
      end)
    end
  end

  describe "Torrent.Swarm endgame pin and safe rank branches" do
    test "endgame stale useless pin moves only to the stable preferred active index" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)
      active = [0, 1]
      preferred_index = endgame_bucket_index(hash, active)

      with_stack(torrent, fn _ ->
        start_downloads(hash)
        Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)
        Downloads.piece(hash, 1, fn -> :ok end, fn -> :ok end)

        piece0 = Piece.whereis(hash, 0)
        assert is_pid(piece0)
        :sys.replace_state(piece0, fn s -> %{s | waiting: [], requests: []} end)
        refute Downloads.piece_has_waiting?(hash, 0)
        assert 0 in Downloads.active_indices(hash)

        target_id = <<0::160>>

        {_pid, key} =
          add_peer(hash, target_id,
            index: 0,
            bitfield: both_pieces(2),
            choke_me: true,
            stale: true
          )

        assert Peer.Controller.stale_useless_pin?(key)
        assert Swarm.assign_peer_to_piece?(hash, key, preferred_index, active)
      end)
    end

    test "assign_peer keeps a pin while the current piece still has waiting subpieces" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [0, 1])

      with_stack(torrent, fn _ ->
        start_downloads(hash)
        Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)
        piece_pid = Piece.whereis(hash, 0)
        TestSupport.Sync.sync(piece_pid)

        {_pid, key} =
          add_peer(hash, @peer_a, index: 0, bitfield: both_pieces(2), choke_me: false)

        refute Swarm.assign_peer_to_piece?(hash, key, 1, [0, 1])
      end)
    end
  end

  describe "Torrent.Controller pump fallback and completion callbacks" do
    test "kick and resume_ready are no-ops when the controller is absent" do
      hash = :crypto.strong_rand_bytes(20)
      assert :ok = Torrent.Controller.kick(hash)
      assert :ok = Torrent.Controller.resume_ready(hash)
    end

    test "no-piece fallback re-interests the active head piece and sets peer_status" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [])

      with_stack(torrent, fn _ ->
        add_peer(hash, @peer_a, bitfield: both_pieces(2), choke_me: false)
        :ok = PiecesStatistic.inc(hash, 0)
        :ok = PiecesStatistic.inc(hash, 1)
        start_downloads(hash)
        Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)
        assert 0 in Downloads.active_indices(hash)
        :ok = PiecesStatistic.reset_availability(hash, 1)

        with_controller(hash, fn pid ->
          send(pid, {:next_piece, :rare})
          TestSupport.Sync.sync(pid)
          assert Model.get(hash, :peer_status) == 0
        end)
      end)
    end

    test "availability mismatch clears stale counts and reconnects discovery" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [])

      with_stack(torrent, fn _ ->
        add_peer(hash, @peer_a, bitfield: Bitfield.make(2))
        :ok = PiecesStatistic.inc(hash, 0)
        assert PiecesStatistic.availability(hash, 0) == 1

        with_controller(hash, fn pid ->
          send(pid, {:next_piece, :random})
          TestSupport.Sync.sync(pid)
          assert PiecesStatistic.availability(hash, 0) == 0
          assert Model.get(hash, :peer_status) == nil
        end)
      end)
    end

    test "orphan reconcile aborts idle active pieces when nobody has unchoked us" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [0, 1])

      with_stack(torrent, fn _ ->
        add_peer(hash, @peer_a, bitfield: both_pieces(2), choke_me: true)
        start_downloads(hash)
        Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)
        piece_pid = Piece.whereis(hash, 0)
        TestSupport.Sync.sync(piece_pid)

        :sys.replace_state(piece_pid, fn state ->
          %{state | waiting: [], requests: []}
        end)

        with_controller(hash, fn pid ->
          send(pid, :reconcile_pump)
          TestSupport.Sync.sync(pid)
          refute Downloads.piece_active?(hash, 0)
        end)
      end)
    end

    test "next_piece reschedules when parallel capacity is already full" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 4, have_indices: [])

      with_stack(torrent, fn _ ->
        add_peer(hash, @peer_a, bitfield: all_pieces(4), choke_me: false)
        for idx <- 0..3, do: :ok = PiecesStatistic.inc(hash, idx)
        start_downloads(hash)
        Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)
        Downloads.piece(hash, 1, fn -> :ok end, fn -> :ok end)
        assert length(Downloads.active_indices(hash)) == 2

        with_controller(hash, fn pid ->
          send(pid, {:next_piece, :rare})
          TestSupport.Sync.sync(pid)
          assert length(Downloads.active_indices(hash)) == 2
        end)
      end)
    end

    test "piece_completed arms superseed when every piece status is complete" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [])

      with_stack(torrent, fn _ ->
        {:ok, superseed} = Torrent.Superseed.start_link(hash)
        on_exit(fn -> TestSupport.Sync.safe_stop(superseed) end)

        add_peer(hash, @peer_a, bitfield: both_pieces(2), choke_me: false)
        :ok = PiecesStatistic.inc(hash, 0)
        :ok = PiecesStatistic.inc(hash, 1)
        start_downloads(hash)

        with_controller(hash, fn pid ->
          send(pid, {:next_piece, :random})
          TestSupport.Sync.sync(pid)
        end)

        [index | _] = Downloads.active_indices(hash)
        piece_pid = Piece.whereis(hash, index)
        assert is_pid(piece_pid)
        %{downloaded: downloaded_cb} = :sys.get_state(piece_pid)

        for idx <- 0..1, do: PiecesStatistic.set(hash, idx, :complete)
        downloaded_cb.()
        assert %{phase: :armed} = :sys.get_state(superseed)
      end)
    end

    test "piece_completed keeps superseed inactive while a sibling piece remains incomplete" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [])

      with_stack(torrent, fn _ ->
        {:ok, superseed} = Torrent.Superseed.start_link(hash)
        on_exit(fn -> TestSupport.Sync.safe_stop(superseed) end)

        add_peer(hash, @peer_a, bitfield: both_pieces(2), choke_me: false)
        :ok = PiecesStatistic.inc(hash, 0)
        :ok = PiecesStatistic.inc(hash, 1)
        start_downloads(hash)

        with_controller(hash, fn pid ->
          send(pid, {:next_piece, :random})
          TestSupport.Sync.sync(pid)
        end)

        [index | _] = Downloads.active_indices(hash)
        other = rem(index + 1, 2)
        piece_pid = Piece.whereis(hash, index)
        assert is_pid(piece_pid)
        %{downloaded: downloaded_cb} = :sys.get_state(piece_pid)

        :ok = PiecesStatistic.set(hash, index, :processing)
        :ok = PiecesStatistic.set(hash, other, nil)

        downloaded_cb.()
        assert %{phase: :inactive} = :sys.get_state(superseed)
      end)
    end

    test "download waiting branch sets connecting_to_peers when no swarm exists" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2, have_indices: [])

      with_model(torrent, fn _ ->
        with_controller(hash, fn pid ->
          send(pid, {:next_piece, :random})
          TestSupport.Sync.sync(pid)
          assert Model.get(hash, :peer_status) == :connecting_to_peers
        end)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count, opts) do
    have = MapSet.new(Keyword.get(opts, :have_indices, []))

    bitfield =
      Enum.reduce(0..(pieces_count - 1), Bitfield.make(pieces_count), fn idx, bf ->
        if MapSet.member?(have, idx), do: Bitfield.set(bf, idx, 1), else: bf
      end)

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "batch", "piece length" => @piece_len}},
      left: pieces_count * @piece_len,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: bitfield,
      peer_status: nil
    }
  end

  defp endgame_torrent(hash) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "endgame", "piece length" => @piece_len}},
      left: 2 * @piece_len,
      last_index: 1,
      last_piece_length: @piece_len,
      bitfield: Bitfield.make(2),
      peer_status: nil
    }
  end

  defp both_pieces(n) do
    n
    |> Bitfield.make()
    |> Bitfield.set(0, 1)
    |> Bitfield.set(1, 1)
  end

  defp all_pieces(n), do: Enum.reduce(0..(n - 1), Bitfield.make(n), &Bitfield.set(&2, &1, 1))

  defp endgame_bucket_index(hash, active_indices) do
    sorted = Enum.sort(active_indices)
    bucket = rem(:erlang.phash2(hash, length(sorted)), length(sorted))
    Enum.at(sorted, bucket)
  end

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Model.start_link(torrent)
    on_exit(fn -> TestSupport.Sync.safe_stop(model_pid) end)
    :ok = PiecesStatistic.init(torrent)
    fun.(torrent.hash)
  end

  defp with_stack(torrent, fun) do
    with_model(torrent, fn hash ->
      start_swarm(hash)
      fun.(hash)
    end)
  end

  defp with_controller(hash, fun) do
    {:ok, pid} = Torrent.Controller.start_link(hash)
    Process.unlink(pid)

    try do
      fun.(pid)
    after
      TestSupport.Sync.safe_stop(pid)
    end
  end

  defp start_swarm(hash) do
    via = {:via, Registry, {Registry, {hash, Swarm}}}

    case DynamicSupervisor.start_link(name: via, strategy: :one_for_one) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_downloads(hash) do
    via = {:via, Registry, {Registry, {hash, Downloads}}}

    case DynamicSupervisor.start_link(
           name: via,
           extra_arguments: [hash],
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp add_peer(hash, id, opts) do
    spec = %{
      id: {:mock_peer, id},
      start: {__MODULE__.MockPeer, :start_link, [hash, id]},
      restart: :temporary
    }

    via = {:via, Registry, {Registry, {hash, Swarm}}}
    {:ok, pid} = DynamicSupervisor.start_child(via, spec)
    key = Peer.make_key(hash, id)
    configure_peer(key, opts)
    {pid, key}
  end

  defp configure_peer(key, opts) do
    now = System.monotonic_time(:millisecond)
    stale? = Keyword.get(opts, :stale, false)
    pinned_at = if stale?, do: now - @stale_ms - 1, else: now

    bitfield =
      Keyword.get(opts, :bitfield, all_pieces(4))

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{
        state
        | bitfield: bitfield,
          status: Keyword.get(opts, :index),
          choke_me: Keyword.get(opts, :choke_me, true),
          choke: Keyword.get(opts, :choke, true),
          interested: true,
          interested_of_me: Keyword.get(opts, :interested_of_me, false),
          rank: Keyword.get(opts, :rank, 0),
          pinned_at: pinned_at,
          pin_downloaded_bytes: 0
      }
    end)
  end

  defp controller_state(key) do
    :sys.get_state({:via, Registry, {Registry, {key, Peer.Controller}}})
  end
end

defmodule TorrentControllerSwarmCoverageBatchTest.MockPeer do
  @moduledoc false
  use GenServer

  def start_link(hash, id) do
    GenServer.start_link(__MODULE__, {hash, id})
  end

  def init({hash, id}) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    {:ok, sender} =
      Peer.Sender.start_link([hash, id, nil])

    {:ok, ctrl} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    Process.monitor(sender)
    Process.monitor(ctrl)
    {:ok, %{controller: ctrl, sender: sender}}
  end

  def handle_info({:DOWN, _, :process, _pid, _}, state), do: {:stop, :normal, state}
end

defmodule PieceAssemblySimulationTest do
  @moduledoc """
  Hunts for a way OUR piece assembly could turn honest blocks into a piece that
  fails its SHA-1.

  Live, a 32-minute session produced three pieces that failed the BEP 3 hash even
  though every byte had arrived. Before blaming the peers (two of them
  qBittorrent), this drives the real `Downloads.Piece.State` + the real
  `FileHandle` with an adversarial-but-HONEST network: every block any peer ever
  sends carries the true bytes, but requests time out and are re-asked, replies
  arrive late (after the request was given to someone else), arrive twice, arrive
  out of order and from peers we never asked, and the torrent flips into endgame
  mid-piece. Whatever the schedule, a piece the state machine calls complete
  must verify. If it ever does not, the bug is ours, not the swarm's.

  The schedules come from a seeded PRNG so a failure is replayable by its seed.
  """

  use ExUnit.Case, async: true

  alias Torrent.Downloads.Piece
  alias Torrent.Downloads.Piece.State
  alias Torrent.FileHandle

  @block Piece.max_length()
  @blocks 8
  @piece_len @blocks * @block
  @peers ["peer-a", "peer-b", "peer-c"]
  @steps 400

  setup do
    hash = :crypto.strong_rand_bytes(20)
    data = :crypto.strong_rand_bytes(@piece_len)
    dir = Path.join(System.tmp_dir!(), "piece_sim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    torrent = %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => "sim.bin",
          "piece length" => @piece_len,
          "length" => @piece_len,
          "pieces" => :crypto.hash(:sha, data)
        }
      },
      left: @piece_len,
      last_index: 0,
      last_piece_length: @piece_len,
      download_dir: dir
    }

    {:ok, model} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    files = start_supervised!({Torrent.FileHandle, hash})

    on_exit(fn ->
      TestSupport.Sync.safe_stop(files, 1_000)
      TestSupport.Sync.safe_stop(model, 1_000)
    end)

    {:ok, hash: hash, data: data}
  end

  test "honest blocks under timeouts, late and duplicate replies always verify", ctx do
    for seed <- 1..300, do: run_schedule(ctx, seed)
  end

  # --- the simulated network -------------------------------------------------

  defp run_schedule(%{hash: hash, data: data}, seed) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})

    # Start every schedule from a blank piece: stale bytes left on disk by the
    # previous seed would let a block that was never written pass the hash.
    FileHandle.write(hash, 0, 0, :binary.copy(<<0>>, @piece_len))
    :ok = FileHandle.flush(hash, 0)

    state = %State{
      State.make({hash, 0})
      | mode: nil,
        requests_are_dealt: fn -> :ok end,
        downloaded: fn -> :ok end,
        # Pre-seeded so State.request/3 does not try to monitor a real peer process.
        monitoring: Map.new(@peers, &{&1, make_ref()})
    }

    # `wire` is what the network still owes us: requests the peers received,
    # including ones the worker has since forgotten (timed out / re-assigned).
    net = %{wire: [], delivered: []}
    drive(state, net, hash, data, seed, @steps)
  end

  defp drive(_state, _net, _hash, _data, seed, 0),
    do: flunk("seed #{seed}: schedule ended without the piece completing")

  defp drive(state, net, hash, data, seed, steps_left) do
    {state, net} = step(state, net, data)

    if complete?(state) do
      assert FileHandle.check?(hash, 0),
             "seed #{seed}: worker declared the piece complete but its bytes fail the hash " <>
               "(honest network) -- assembly bug: #{inspect(Map.take(state, [:waiting, :requests, :mode]))}"
    else
      drive(state, net, hash, data, seed, steps_left - 1)
    end
  end

  defp complete?(%State{waiting: [], requests: []}), do: true
  defp complete?(_), do: false

  # Cumulative percentage -> operation; every operation is `op(state, net, data)`.
  @schedule [
    {30, :ask},
    {70, :deliver},
    {80, :duplicate},
    {90, :timeout},
    {94, :endgame},
    {100, :unsolicited}
  ]

  defp step(state, net, data) do
    roll = :rand.uniform(100)
    {_upto, op} = Enum.find(@schedule, fn {upto, _op} -> roll <= upto end)
    operation(op).(state, net, data)
  end

  defp operation(:ask), do: &ask/3
  defp operation(:deliver), do: &deliver/3
  defp operation(:duplicate), do: &duplicate/3
  defp operation(:timeout), do: &timeout/3
  defp operation(:endgame), do: &endgame/3
  defp operation(:unsolicited), do: &unsolicited/3

  defp ask(state, net, _data) do
    peer = Enum.random(@peers)
    test_pid = self()
    cb = fn _index, begin, length -> send(test_pid, {:wire, peer, begin, length}) end
    state = State.request(state, peer, cb)

    receive do
      {:wire, ^peer, begin, length} -> {state, %{net | wire: [{peer, begin, length} | net.wire]}}
    after
      0 -> {state, net}
    end
  end

  defp deliver(state, %{wire: []} = net, _data), do: {state, net}

  defp deliver(state, %{wire: wire} = net, data) do
    {peer, begin, length} = Enum.random(wire)
    block = binary_part(data, begin, length)
    state = State.response(state, peer, begin, block)

    {state,
     %{
       net
       | wire: List.delete(wire, {peer, begin, length}),
         delivered: [{peer, begin, length} | net.delivered]
     }}
  end

  defp duplicate(state, %{delivered: []} = net, _data), do: {state, net}

  defp duplicate(state, %{delivered: delivered} = net, data) do
    {peer, begin, length} = Enum.random(delivered)
    {State.response(state, peer, begin, binary_part(data, begin, length)), net}
  end

  # The worker gives up on a peer's in-flight blocks; the bytes may still arrive.
  defp timeout(state, net, _data), do: {State.timeout(state, Enum.random(@peers)), net}

  defp endgame(state, net, _data), do: {State.enter_endgame(state), net}

  # A peer answers a block we never asked it for (cancel race / hostile-but-honest).
  defp unsolicited(state, net, data) do
    begin = Enum.random(0..(@blocks - 1)) * @block
    peer = Enum.random(@peers)
    {State.response(state, peer, begin, binary_part(data, begin, @block)), net}
  end
end

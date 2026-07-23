defmodule TorrentControllerParallelTest do
  use ExUnit.Case, async: false

  alias Torrent.{Downloads, PiecesStatistic, Swarm}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "Torrent.Controller.effective_max_parallel/1" do
    test "returns 1 when no peers have unchoked us" do
      assert Torrent.Controller.effective_max_parallel(0) == 1
    end

    test "returns 2 for a single unchoked peer" do
      assert Torrent.Controller.effective_max_parallel(1) == 2
    end

    test "scales with unchoked count until the nominal cap" do
      assert Torrent.Controller.effective_max_parallel(3) == 6
      assert Torrent.Controller.effective_max_parallel(6) == 12
      assert Torrent.Controller.effective_max_parallel(10) == 12
    end
  end

  describe "Torrent.Swarm.unchoked_for_us_count/1" do
    test "counts connected peers where choke_me? is false" do
      hash = :crypto.strong_rand_bytes(20)
      start_model(hash)
      start_swarm(hash)

      add_mock_peers(hash, [
        [id: <<1::160>>, choke_me: false],
        [id: <<2::160>>, choke_me: true],
        [id: <<3::160>>, choke_me: false]
      ])

      assert Swarm.unchoked_for_us_count(hash) == 2
    end

    test "returns zero when the swarm supervisor is missing" do
      hash = :crypto.strong_rand_bytes(20)
      assert Swarm.unchoked_for_us_count(hash) == 0
    end

    test "treats eviction_info failures as choked" do
      hash = :crypto.strong_rand_bytes(20)
      start_swarm(hash)

      spec = %{
        id: :dummy_peer,
        start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]},
        restart: :temporary
      }

      {:ok, _} = DynamicSupervisor.start_child(swarm_via(hash), spec)
      assert Swarm.count(hash) == 1
      assert Swarm.unchoked_for_us_count(hash) == 0
    end
  end

  describe "download pump parallel cap" do
    @pieces_count 12

    test "does not grow active pieces beyond 2 with one unchoked peer" do
      hash = setup_pump_scenario(unchoked: 1, choked: 1)
      controller_pid = start_controller(hash)

      drive_pump(controller_pid, 2_000)

      assert length(Downloads.active_indices(hash)) <= 2
    end

    test "allows up to 12 active pieces with many unchoked peers" do
      hash = setup_pump_scenario(unchoked: 8, choked: 0)
      controller_pid = start_controller(hash)

      drive_pump(controller_pid, 4_000)

      assert length(Downloads.active_indices(hash)) >= 8
      assert length(Downloads.active_indices(hash)) <= 12
    end
  end

  ## helpers -----------------------------------------------------------------

  defp swarm_via(hash), do: {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

  defp downloads_via(hash), do: {:via, Registry, {Registry, {hash, Torrent.Downloads}}}

  defp start_swarm(hash) do
    case DynamicSupervisor.start_link(name: swarm_via(hash), strategy: :one_for_one) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_downloads(hash) do
    case DynamicSupervisor.start_link(
           name: downloads_via(hash),
           extra_arguments: [hash],
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_model(hash) do
    torrent = sample_torrent(hash)
    {:ok, pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      safe_stop(pid)
    end)

    :ok
  end

  defp sample_torrent(hash) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "parallel-cap", "piece length" => 16_384}},
      left: @pieces_count * 16_384,
      last_index: @pieces_count - 1,
      last_piece_length: 16_384,
      peer_status: nil
    }
  end

  defp setup_pump_scenario(unchoked: unchoked_count, choked: choked_count) do
    hash = :crypto.strong_rand_bytes(20)
    torrent = sample_torrent(hash)

    {:ok, model_pid} = Torrent.Model.start_link(torrent)
    :ok = PiecesStatistic.init(torrent)
    :ok = PiecesStatistic.inc_all(hash, torrent.last_index)

    start_swarm(hash)
    start_downloads(hash)

    unchoked_configs =
      for i <- 1..unchoked_count do
        [id: <<i::160>>, choke_me: false, bitfield: :all]
      end

    choked_configs =
      if choked_count > 0 do
        for i <- 1..choked_count do
          [id: <<(100 + i)::160>>, choke_me: true, bitfield: :all]
        end
      else
        []
      end

    add_mock_peers(hash, unchoked_configs ++ choked_configs)

    on_exit(fn ->
      safe_stop(model_pid)

      case GenServer.whereis(swarm_via(hash)) do
        nil -> :ok
        pid -> safe_stop(pid)
      end

      case GenServer.whereis(downloads_via(hash)) do
        nil -> :ok
        pid -> safe_stop(pid)
      end
    end)

    hash
  end

  defp start_controller(hash) do
    {:ok, pid} = GenServer.start(Torrent.Controller, hash)

    on_exit(fn ->
      safe_stop(pid)
    end)

    pid
  end

  defp drive_pump(controller_pid, duration_ms) do
    send(controller_pid, {:next_piece, :random})

    deadline = System.monotonic_time(:millisecond) + duration_ms

    Stream.repeatedly(fn ->
      send(controller_pid, :reconcile_pump)
      send(controller_pid, {:next_piece, :rare})
      Process.sleep(250)
    end)
    |> Enum.take_while(fn _ ->
      System.monotonic_time(:millisecond) < deadline
    end)

    :ok
  end

  defp add_mock_peers(hash, configs) do
    Enum.each(configs, fn opts ->
      id = Keyword.fetch!(opts, :id)

      spec = %{
        id: {:mock_peer, id},
        start: {__MODULE__.MockPeer, :start_link, [hash, id, opts]},
        restart: :temporary
      }

      {:ok, _} = DynamicSupervisor.start_child(swarm_via(hash), spec)
    end)
  end

  defp safe_stop(pid) when is_pid(pid) do
    try do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end
end

defmodule TorrentControllerParallelTest.MockPeer do
  @moduledoc false
  use GenServer

  def start_link(hash, id, opts) do
    GenServer.start_link(__MODULE__, {hash, id, opts})
  end

  def init({hash, id, opts}) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    {:ok, ctrl} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    Process.monitor(ctrl)

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{
        state
        | bitfield: Keyword.get(opts, :bitfield, :all),
          choke_me: Keyword.get(opts, :choke_me, true),
          interested: true
      }
    end)

    {:ok, %{controller: ctrl}}
  end

  def handle_info({:DOWN, _, :process, _ctrl, _}, state), do: {:stop, :normal, state}
end

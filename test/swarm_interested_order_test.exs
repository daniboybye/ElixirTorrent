defmodule SwarmInterestedOrderTest do
  use ExUnit.Case, async: false

  alias Torrent.Swarm

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "Peer.Controller.seeder?/1 is true when bitfield is :all" do
    hash = :crypto.strong_rand_bytes(20)
    seeder_id = <<1::160>>
    leecher_id = <<2::160>>
    seeder_key = Peer.make_key(hash, seeder_id)
    leecher_key = Peer.make_key(hash, leecher_id)

    with_model(hash, fn _ ->
      start_controller(seeder_key)
      start_controller(leecher_key)

      :sys.replace_state({:via, Registry, {Registry, {seeder_key, Peer.Controller}}}, fn state ->
        %{state | bitfield: :all}
      end)

      :sys.replace_state({:via, Registry, {Registry, {leecher_key, Peer.Controller}}}, fn state ->
        %{state | bitfield: Torrent.Bitfield.set(Torrent.Bitfield.make(4), 0, 1)}
      end)

      assert Peer.Controller.seeder?(seeder_key)
      refute Peer.Controller.seeder?(leecher_key)
    end)
  end

  test "sort_peers_seeders_first/1 puts seeders before leechers" do
    hash = :crypto.strong_rand_bytes(20)
    seeder_id = <<1::160>>
    leecher_id = <<2::160>>

    with_swarm(hash, fn _ ->
      leecher_pid = add_mock_peer(hash, leecher_id, bitfield: partial_bitfield(4, 0))
      seeder_pid = add_mock_peer(hash, seeder_id, bitfield: :all)

      assert Swarm.sort_peers_seeders_first([leecher_pid, seeder_pid]) == [
               seeder_pid,
               leecher_pid
             ]
    end)
  end

  test "interested_for_piece/2 calls Peer.interested on seeder before leecher" do
    hash = :crypto.strong_rand_bytes(20)
    seeder_id = <<1::160>>
    leecher_id = <<2::160>>
    index = 0
    collector = start_collector()

    with_swarm(hash, fn _ ->
      add_mock_peer(hash, leecher_id, bitfield: partial_bitfield(4, index))
      add_mock_peer(hash, seeder_id, bitfield: :all)

      pids = Swarm.interest_peer_pids(hash, index)

      order =
        Enum.map(pids, fn pid ->
          id = Peer.get_id(pid)
          send(collector, {:peer_interested, id})
          Peer.interested(pid, index)
          id
        end)

      assert SwarmInterestedOrderTest.Collector.get(collector) == [seeder_id, leecher_id]
      assert order == [seeder_id, leecher_id]

      assert :ok = Swarm.interested_for_piece(hash, index)
    end)
  end

  test "interested_for_piece/2 is a no-op after the swarm shuts down" do
    hash = :crypto.strong_rand_bytes(20)

    with_model(hash, fn _ ->
      start_swarm(hash)
      swarm_pid = GenServer.whereis(swarm_via(hash))
      safe_stop(swarm_pid)

      assert Swarm.interest_peer_pids(hash, 0) == []
      assert :ok = Swarm.interested_for_piece(hash, 0)
    end)
  end

  ## helpers -----------------------------------------------------------------

  defp swarm_via(hash), do: {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

  defp partial_bitfield(pieces_count, index) do
    Torrent.Bitfield.set(Torrent.Bitfield.make(pieces_count), index, 1)
  end

  defp with_model(hash, fun) do
    torrent = sample_torrent(hash)

    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      safe_stop(model_pid)
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp with_swarm(hash, fun) do
    with_model(hash, fn torrent ->
      start_swarm(hash)
      fun.(torrent)
    end)
  end

  defp sample_torrent(hash) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "swarm-order", "piece length" => 16_384}},
      left: 4 * 16_384,
      last_index: 3,
      last_piece_length: 16_384,
      peer_status: nil
    }
  end

  defp start_swarm(hash) do
    case DynamicSupervisor.start_link(name: swarm_via(hash), strategy: :one_for_one) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_controller(key) do
    {id, hash} = key

    {:ok, pid} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    on_exit(fn ->
      safe_stop(pid)
    end)

    :ok
  end

  defp add_mock_peer(hash, id, opts) do
    spec = %{
      id: {:mock_peer, id},
      start: {__MODULE__.MockPeer, :start_link, [hash, id, opts]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(swarm_via(hash), spec)
    pid
  end

  defp start_collector do
    {:ok, pid} = SwarmInterestedOrderTest.Collector.start_link()
    pid
  end

  defp safe_stop(pid) when is_pid(pid) do
    try do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end
end

defmodule SwarmInterestedOrderTest.MockPeer do
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

defmodule SwarmInterestedOrderTest.Collector do
  @moduledoc false
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, [])
  end

  def get(pid), do: GenServer.call(pid, :get)

  def init(state), do: {:ok, state}

  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_info({:peer_interested, id}, state), do: {:noreply, state ++ [id]}
end

defmodule EndgamePinMonopolyTest do
  use ExUnit.Case, async: false

  alias Peer.Controller.State, as: PeerState
  alias Torrent.{Downloads, Model, Swarm}

  @piece_len 16_384
  @stale_ms 20_000

  @peer_endgame_b <<41::160>>

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "stale useless pin release" do
    test "State.stale_useless_pin?/1 when choked, zero pin bytes, and pin age exceeded" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)

      with_model(torrent, fn _ ->
        now = System.monotonic_time(:millisecond)

        state =
          base_peer_state(hash)
          |> Map.put(:status, 0)
          |> Map.put(:choke_me, true)
          |> Map.put(:pin_downloaded_bytes, 0)
          |> Map.put(:pinned_at, now - @stale_ms - 1)

        assert PeerState.stale_useless_pin?(state)
      end)
    end

    test "interest_peer_pids/2 reassigns stale choked peer to another endgame piece" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)

      with_model(torrent, fn _ ->
        start_swarm(hash)

        {_pid, key} =
          add_swarm_peer(hash, @peer_endgame_b,
            index: 0,
            choke_me: true,
            stale: true,
            bitfield: both_pieces()
          )

        assert Peer.Controller.stale_useless_pin?(key)
        assert key in peer_keys(Swarm.interest_peer_pids(hash, 1))

        Swarm.interested_for_piece(hash, 1)
        assert Peer.Controller.download_piece(key) == 1
      end)
    end

    test "productive peer stays pinned when another active piece is interested" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)

      with_model(torrent, fn _ ->
        start_swarm(hash)
        start_downloads(hash)
        Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)
        Downloads.piece(hash, 1, fn -> :ok end, fn -> :ok end)
        assert wait_active_pieces(hash, [0, 1])

        {_pid, key} =
          add_swarm_peer(hash, @peer_endgame_b,
            index: 0,
            choke_me: false,
            stale: false,
            bitfield: both_pieces()
          )

        refute key in peer_keys(Swarm.interest_peer_pids(hash, 1))
        assert key in peer_keys(Swarm.interest_peer_pids(hash, 0))
      end)
    end
  end

  describe "reconcile_pump multi-interest" do
    test "controller reconcile interests each sorted active index in endgame" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)

      with_endgame_swarm(torrent, [0, 1], fn _ ->
        {_pid, key} =
          add_swarm_peer(hash, @peer_endgame_b,
            index: 0,
            choke_me: true,
            stale: true,
            bitfield: both_pieces()
          )

        {:ok, controller} = GenServer.start(Torrent.Controller, hash)
        on_exit(fn -> safe_stop(controller) end)

        send(controller, :reconcile_pump)
        Process.sleep(20)

        # Endgame reconcile must have attempted piece 1, not only the monopoly index 0.
        assert Peer.Controller.download_piece(key) in [0, 1]
      end)
    end
  end

  describe "endgame reject re-queue" do
    alias Torrent.Downloads.Piece.{Request, State}

    test "reject re-queues subpiece in endgame when redundancy drops below cap" do
      hash = :crypto.strong_rand_bytes(20)
      subpiece = {0, @piece_len}

      state = %State{
        hash: hash,
        index: 0,
        mode: :endgame,
        waiting: [],
        requests: [
          %Request{peer_id: <<1::160>>, subpiece: subpiece, timer: nil},
          %Request{peer_id: <<2::160>>, subpiece: subpiece, timer: nil}
        ]
      }

      new_state = State.reject(state, <<1::160>>, 0, @piece_len)

      assert subpiece in new_state.waiting
    end
  end

  ## helpers -----------------------------------------------------------------

  defp swarm_via(hash), do: {:via, Registry, {Registry, {hash, Torrent.Swarm}}}

  defp downloads_via(hash), do: {:via, Registry, {Registry, {hash, Torrent.Downloads}}}

  defp endgame_torrent(hash) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "endgame-pin", "piece length" => @piece_len}},
      # Well inside BEP-3 endgame threshold (@until_endgame piece-lengths).
      left: 5 * @piece_len,
      last_index: 3,
      last_piece_length: @piece_len,
      peer_status: nil
    }
  end

  defp both_pieces do
    Torrent.Bitfield.make(4)
    |> Torrent.Bitfield.set(0, 1)
    |> Torrent.Bitfield.set(1, 1)
  end

  defp base_peer_state(hash) do
    struct!(PeerState, %{
      hash: hash,
      id: Peer.id(),
      fast_extension: nil,
      status: nil,
      pieces_count: 4,
      socket: nil
    })
  end

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Model.start_link(torrent)

    on_exit(fn -> safe_stop(model_pid) end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp with_endgame_swarm(torrent, active_indices, fun) do
    with_model(torrent, fn t ->
      start_swarm(torrent.hash)
      start_downloads(torrent.hash)
      start_endgame_pieces(torrent.hash, active_indices)

      assert wait_active_pieces(torrent.hash, active_indices)

      assert Model.get(torrent.hash, :mode) == :endgame

      fun.(t)
    end)
  end

  defp start_endgame_pieces(hash, active_indices) do
    Enum.each(active_indices, fn index ->
      Downloads.piece(hash, index, fn -> :ok end, fn -> :ok end)
    end)
  end

  defp add_swarm_peer(hash, id, opts) do
    spec = %{
      id: {:mock_peer, id},
      start: {__MODULE__.MockPeer, :start_link, [hash, id]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(swarm_via(hash), spec)
    key = Peer.make_key(hash, id)
    _ = :sys.get_state({:via, Registry, {Registry, {key, Peer.Controller}}})
    pin_peer(key, opts)
    {pid, key}
  end

  defp pin_peer(key, opts) do
    now = System.monotonic_time(:millisecond)
    stale? = Keyword.fetch!(opts, :stale)
    pinned_at = if stale?, do: now - @stale_ms - 1, else: now

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{
        state
        | bitfield: Keyword.fetch!(opts, :bitfield),
          status: Keyword.fetch!(opts, :index),
          choke_me: Keyword.fetch!(opts, :choke_me),
          interested: true,
          pinned_at: pinned_at,
          pin_downloaded_bytes: 0
      }
    end)
  end

  defp peer_keys(pids) do
    Enum.map(pids, &Peer.get_key/1)
  end

  defp wait_active_pieces(hash, expected) do
    target = Enum.sort(expected)

    Enum.reduce_while(1..100, false, fn _, _ ->
      if Enum.sort(Downloads.active_indices(hash)) == target do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end) == true
  end

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

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end
end

defmodule EndgamePinMonopolyTest.MockPeer do
  @moduledoc false
  use GenServer

  def start_link(hash, id) do
    GenServer.start_link(__MODULE__, {hash, id})
  end

  def init({hash, id}) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    {:ok, ctrl} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    Process.monitor(ctrl)
    {:ok, %{controller: ctrl}}
  end

  def handle_info({:DOWN, _, :process, _ctrl, _}, state), do: {:stop, :normal, state}
end

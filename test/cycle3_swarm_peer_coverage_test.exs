defmodule Cycle3SwarmPeerCoverageTest do
  @moduledoc """
  Deterministic coverage for `Torrent.Swarm`'s BEP 3 choke algorithm and for the
  `Peer` pid→key wrappers.

  The choke cycle is the upload side of BEP 3: a seeder may only serve a bounded
  number of peers at once, so every ~10 s it ranks interested peers by how much
  they gave us, keeps the top 4 ("tit-for-tat") plus one random "optimistic
  unchoke" slot (so a peer that has never traded gets a chance to prove itself),
  and chokes everyone else. `Torrent.Swarm.unchoke/1` implements exactly that,
  and all of its failure paths are `catch :exit` guards, because a peer process
  can die between `which_children/1` and the per-peer call.
  """
  use ExUnit.Case, async: false

  alias Cycle3SwarmPeerCoverageTest.{ControllerStub, PeerStub}

  @piece_len 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "Torrent.Swarm.unchoke/1 choke cycle" do
    test "skips the cycle when the torrent has nothing to offer" do
      hash = new_hash()
      start_swarm(hash)
      start_model(hash, left: @piece_len)

      assert :ok = Torrent.Swarm.unchoke(hash)
    end

    test "a dead Model makes offers_pieces? fail closed" do
      hash = new_hash()
      start_swarm(hash)

      # No Model at all: Torrent.Model.downloaded?/1 exits :noproc and the
      # unchoke cycle must degrade to "offer nothing" rather than crash the
      # torrent's controller.
      assert :ok = Torrent.Swarm.unchoke(hash)
    end

    test "runs the cycle with no peers" do
      hash = new_hash()
      start_swarm(hash)
      start_model(hash, left: 0)

      assert :ok = Torrent.Swarm.unchoke(hash)
    end

    test "with four interested peers every rank fits in the tit-for-tat slots" do
      hash = new_hash()
      start_swarm(hash)
      start_model(hash, left: 0)

      ids = for i <- 1..4, do: add_ranked_peer(hash, i * 10)

      assert :ok = Torrent.Swarm.unchoke(hash)

      for id <- ids, do: assert_receive({:controller, ^id, :unchoke}, 2_000)
      refute_received {:controller, _, :choke}
    end

    test "with more peers than slots the surplus is choked and one is optimistic" do
      hash = new_hash()
      start_swarm(hash)
      start_model(hash, left: 0)

      ids = for i <- 1..8, do: add_ranked_peer(hash, i * 10)

      assert :ok = Torrent.Swarm.unchoke(hash)

      decisions =
        for _ <- ids do
          assert_receive {:controller, id, verb}, 2_000
          {id, verb}
        end

      assert length(decisions) == 8
      unchoked = for {id, :unchoke} <- decisions, do: id
      choked = for {id, :choke} <- decisions, do: id

      # BEP 3: 4 tit-for-tat slots + 1 optimistic unchoke.
      assert length(unchoked) == 6
      assert length(choked) == 2
      assert Enum.sort(unchoked ++ choked) == Enum.sort(ids)
    end

    test "peers whose rank call exits or who are unregistered are dropped" do
      hash = new_hash()
      start_swarm(hash)
      start_model(hash, left: 0)

      ranked = add_ranked_peer(hash, 100)
      # Registered as a peer but with no Controller: Peer.rank/1 exits and
      # safe_rank/1 has to swallow it.
      _no_controller = add_peer_without_controller(hash)
      # Not in the Registry at all: Peer.get_key/1 returns nil, so Peer.rank/1
      # answers nil and the peer contributes no rank.
      _unregistered = add_unregistered_peer(hash)

      assert :ok = Torrent.Swarm.unchoke(hash)

      assert_receive {:controller, ^ranked, :unchoke}, 2_000
      refute_received {:controller, _, :choke}
    end

    test "a peer op that exits mid-cycle does not abort the cycle" do
      hash = new_hash()
      start_swarm(hash)
      start_model(hash, left: 0)

      dying = add_ranked_peer(hash, 50)
      survivor = add_ranked_peer(hash, 10)

      # Kill the controller after its rank was collected: apply_choke_cycle/3
      # then casts into a dead name, which safe_peer_op/1 must absorb.
      :ok = ControllerStub.stop(hash, dying)

      assert :ok = Torrent.Swarm.unchoke(hash)
      assert_receive {:controller, ^survivor, :unchoke}, 2_000
    end
  end

  describe "Torrent.Swarm peer probes fail closed" do
    test "confirmed_seed_count/1 and sorting ignore unregistered children" do
      hash = new_hash()
      start_swarm(hash)

      seeder = add_ranked_peer(hash, 10, seeder?: true)
      _unregistered = add_unregistered_peer(hash)

      assert Torrent.Swarm.confirmed_seed_count(hash) == 1

      pids = Torrent.Swarm.peer_supervisors(hash)
      assert length(pids) == 2
      # peer_seeder_rank/1 ranks: seeder 0, leecher 1, unregistered 2.
      assert [first | _] = Torrent.Swarm.sort_peers_seeders_first(pids)
      assert Peer.get_key(first) == Peer.make_key(hash, seeder)
    end

    test "interest_peer_pids/2 skips unregistered children" do
      hash = new_hash()
      start_swarm(hash)
      _unregistered = add_unregistered_peer(hash)

      assert Torrent.Swarm.interest_peer_pids(hash, 0) == []
      assert :ok = Torrent.Swarm.interested(hash, 0)
    end

    test "any_has_piece?/2 fails closed for unregistered and controller-less peers" do
      hash = new_hash()
      start_swarm(hash)
      _unregistered = add_unregistered_peer(hash)
      _no_controller = add_peer_without_controller(hash)

      refute Torrent.Swarm.any_has_piece?(hash, 0)
    end

    test "unchoked_for_us_count/1 counts a probe exit as choked" do
      hash = new_hash()
      start_swarm(hash)
      _no_controller = add_peer_without_controller(hash)

      assert Torrent.Swarm.unchoked_for_us_count(hash) == 0
    end

    test "add/4 without a swarm supervisor reports :noproc" do
      hash = new_hash()

      assert {:error, :noproc} =
               Torrent.Swarm.add(hash, peer_id(), <<0::64>>, nil)
    end
  end

  describe "Peer pid wrappers" do
    test "delegate to the Controller for a registered peer" do
      hash = new_hash()
      id = peer_id()
      pid = start_peer(hash, id)
      {:ok, _} = ControllerStub.start(hash, id, self(), rank: {0, id})

      assert :ok = Peer.choke(hash, id)
      assert_receive {:controller, ^id, :choke}, 2_000

      assert :ok = Peer.unchoke(hash, id)
      assert_receive {:controller, ^id, :unchoke}, 2_000

      assert :ok = Peer.reset_rank(pid)
      assert_receive {:controller, ^id, :reset_rank}, 2_000

      assert {0, ^id} = Peer.rank(pid)

      assert :ok = Peer.seed(pid)
      assert_receive {:controller, ^id, :seed}, 2_000

      assert :ok = Peer.send_pex(pid, <<1, 2, 3>>)
      assert_receive {:controller, ^id, :send_pex}, 2_000

      assert Peer.peer_v2_support?(pid) == true

      assert {:ok, ref} = Peer.request_hashes(pid, hash_request())
      assert is_reference(ref)

      assert :ok = Peer.start_protocol(pid)
    end

    test "Peer.port/2 delegates to the Sender" do
      hash = new_hash()
      id = peer_id()
      pid = start_peer(hash, id)
      {:ok, _} = SenderStub.start(hash, id, self())

      assert :ok = Peer.port(pid, 6881)
      assert_receive {:sender, ^id, :port, 6881}, 2_000
    end

    test "wrappers answer nil for a pid that is not a registered peer" do
      pid = spawn_idle()

      assert Peer.rank(pid) == nil
      assert Peer.reset_rank(pid) == nil
      assert Peer.seed(pid) == nil
      assert Peer.port(pid, 6881) == nil
      assert Peer.send_pex(pid, <<>>) == nil
      assert Peer.peer_v2_support?(pid) == nil
      assert Peer.request_hashes(pid, hash_request()) == nil
    end

    test "start_protocol/1 reports an unregistered pid and swallows an exit" do
      pid = spawn_idle()
      assert {:error, :peer_not_registered} = Peer.start_protocol(pid)

      hash = new_hash()
      id = peer_id()
      registered = start_peer(hash, id)
      # Registered but with no Controller behind the name: the GenServer.call
      # exits :noproc and start_protocol/1 turns that into an error tuple.
      assert {:error, {:noproc, _}} = Peer.start_protocol(registered)
    end

    test "log_id/1 renders a missing peer id" do
      assert Peer.log_id(nil) == "?"
    end
  end

  ## helpers -----------------------------------------------------------------

  defp new_hash, do: :crypto.strong_rand_bytes(20)

  # A remote peer id, distinct from our own `Peer.id/0`, so each stub gets its
  # own Registry key.
  defp peer_id, do: :crypto.strong_rand_bytes(20)

  defp hash_request do
    %Peer.HashWire{
      pieces_root: :binary.copy(<<7>>, 32),
      base_layer: 0,
      index: 0,
      length: 2,
      proof_layers: 0
    }
  end

  defp start_swarm(hash) do
    {:ok, pid} =
      DynamicSupervisor.start_link(
        name: {:via, Registry, {Registry, {hash, Torrent.Swarm}}},
        strategy: :one_for_one,
        max_restarts: 0
      )

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp start_model(hash, opts) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "swarm", "piece length" => @piece_len}},
      left: Keyword.fetch!(opts, :left),
      last_index: 0,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(1)
    }

    {:ok, pid} = Torrent.Model.start_link(torrent)
    on_exit(fn -> stop_quietly(pid) end)
    :ok = Torrent.PiecesStatistic.init(torrent)
    pid
  end

  # A peer child under the swarm supervisor, registered under {key, Peer} like
  # the real Peer supervisor is.
  defp start_peer(hash, id, sup \\ nil) do
    {:ok, pid} = start_peer_child(sup, PeerStub, {hash, id})
    pid
  end

  defp add_ranked_peer(hash, upload, opts \\ []) do
    id = peer_id()
    sup = swarm_sup(hash)
    start_peer(hash, id, sup)

    {:ok, controller} =
      ControllerStub.start(hash, id, self(),
        rank: {upload, id},
        seeder?: Keyword.get(opts, :seeder?, false)
      )

    on_exit(fn -> stop_quietly(controller) end)
    id
  end

  defp add_peer_without_controller(hash) do
    start_peer(hash, peer_id(), swarm_sup(hash))
  end

  defp add_unregistered_peer(hash) do
    {:ok, pid} = start_peer_child(swarm_sup(hash), PeerStub, :unregistered)
    pid
  end

  defp start_peer_child(nil, module, arg) do
    {:ok, pid} = GenServer.start(module, arg)
    on_exit(fn -> stop_quietly(pid) end)
    {:ok, pid}
  end

  defp start_peer_child(sup, module, arg) do
    DynamicSupervisor.start_child(sup, %{
      id: make_ref(),
      start: {GenServer, :start_link, [module, arg]},
      restart: :temporary
    })
  end

  defp swarm_sup(hash), do: GenServer.whereis({:via, Registry, {Registry, {hash, Torrent.Swarm}}})

  defp spawn_idle do
    {:ok, pid} = GenServer.start(PeerStub, :unregistered)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp stop_quietly(pid) when is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
  defp stop_quietly(_), do: :ok
end

defmodule Cycle3SwarmPeerCoverageTest.PeerStub do
  @moduledoc false
  use GenServer

  @impl GenServer
  def init(:unregistered), do: {:ok, nil}

  def init({hash, id}) do
    key = Peer.make_key(hash, id)
    {:ok, _} = Registry.register(Registry, {key, Peer}, nil)
    {:ok, key}
  end
end

defmodule Cycle3SwarmPeerCoverageTest.ControllerStub do
  @moduledoc false
  use GenServer

  @spec start(Torrent.hash(), Peer.id(), pid(), keyword()) :: GenServer.on_start()
  def start(hash, id, test_pid, opts \\ []) do
    key = Peer.make_key(hash, id)

    GenServer.start(__MODULE__, {key, id, test_pid, opts},
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  @spec stop(Torrent.hash(), Peer.id()) :: :ok
  def stop(hash, id) do
    name = {:via, Registry, {Registry, {Peer.make_key(hash, id), Peer.Controller}}}

    case GenServer.whereis(name) do
      nil -> :ok
      pid -> TestSupport.Sync.safe_stop(pid, 500)
    end
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call(:rank, _from, {_key, _id, _test, opts} = state),
    do: {:reply, Keyword.get(opts, :rank), state}

  def handle_call(:has_all?, _from, {_key, _id, _test, opts} = state),
    do: {:reply, Keyword.get(opts, :seeder?, false), state}

  def handle_call(:peer_v2_support?, _from, state), do: {:reply, true, state}

  def handle_call(:start_protocol, _from, state), do: {:reply, :ok, state}

  def handle_call({:request_hashes, _req, _timeout, _from_pid}, _from, state),
    do: {:reply, {:ok, make_ref()}, state}

  def handle_call({:has_index?, _index}, _from, state), do: {:reply, false, state}

  def handle_call(:eviction_info, _from, state), do: {:reply, %{choke_me?: true}, state}

  @impl GenServer
  def handle_cast({verb, _args}, {_key, id, test_pid, _opts} = state) do
    send(test_pid, {:controller, id, verb})
    {:noreply, state}
  end
end

defmodule SenderStub do
  @moduledoc false
  use GenServer

  @spec start(Torrent.hash(), Peer.id(), pid()) :: GenServer.on_start()
  def start(hash, id, test_pid) do
    key = Peer.make_key(hash, id)

    GenServer.start(__MODULE__, {id, test_pid},
      name: {:via, Registry, {Registry, {key, Peer.Sender}}}
    )
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_cast({verb, arg}, {id, test_pid} = state) do
    send(test_pid, {:sender, id, verb, arg})
    {:noreply, state}
  end
end

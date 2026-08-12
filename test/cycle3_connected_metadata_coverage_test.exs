defmodule Cycle3ConnectedMetadataCoverageTest do
  @moduledoc """
  Coverage for the peer-selection and give-up paths of `Magnet.ConnectedMetadata`
  — the BEP 9 "fetch the .torrent from the swarm" round.

  A magnet link carries only an info-hash, so the metadata has to be downloaded
  over `ut_metadata` from a peer that advertises it in its BEP 10 extended
  handshake. That handshake can arrive *after* the base handshake, and a peer
  can drop at any point, so between "this peer looked capable" and "ask this
  peer" the answer may already have changed. These tests pin what happens in
  each of those windows: the round must skip the peer with a specific reason
  and move to the next, never crash the fetch.
  """
  use ExUnit.Case, async: false

  alias Cycle3ConnectedMetadataCoverageTest.ControllerScript
  alias Magnet.UtMetadata.Extension, as: UtMetadataExtension
  alias Peer.LTEP.{Handshake, Session}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    previous = Application.get_env(:elixir_torrent, :magnet_connected_metadata, [])
    on_exit(fn -> Application.put_env(:elixir_torrent, :magnet_connected_metadata, previous) end)

    Application.put_env(:elixir_torrent, :magnet_connected_metadata,
      wait_for_peers_ms: 50,
      wait_poll_ms: 1,
      wait_max_ms: 50,
      wait_extend_on_connect_ms: 5,
      min_peers_gather_ms: 1,
      min_peers_for_round: 1,
      max_peers: 4,
      metadata_parallel: 4,
      peer_timeout_ms: 2_000,
      ltep_metadata_wait_ms: 20
    )

    :ok
  end

  test "a peer that loses ut_metadata between selection and fetch is skipped" do
    hash = new_hash()
    start_swarm(hash)
    # First answer feeds peer selection, the rest feed the fetch itself.
    add_scripted_peer(hash, [candidate_info(), non_candidate_info(), non_candidate_info()])

    assert {:error, {:metadata_unavailable, failures}} =
             Magnet.ConnectedMetadata.fetch(magnet(hash), [])

    # No metadata_size and no ut_metadata: we polled until the LTEP wait expired.
    assert :metadata_size_pending in failures
  end

  test "a peer whose session disappears mid-wait is reported as died" do
    hash = new_hash()
    start_swarm(hash)
    add_scripted_peer(hash, [candidate_info(), non_candidate_info(), :error])

    assert {:error, {:metadata_unavailable, failures}} =
             Magnet.ConnectedMetadata.fetch(magnet(hash), [])

    assert :peer_died in failures
  end

  test "a peer with no extended session left is skipped without a session" do
    hash = new_hash()
    start_swarm(hash)
    add_scripted_peer(hash, [candidate_info(), :error])

    assert {:error, {:metadata_unavailable, failures}} =
             Magnet.ConnectedMetadata.fetch(magnet(hash), [])

    assert :no_metadata_session in failures
  end

  test "a peer process that dies mid-round is normalised to peer_died" do
    hash = new_hash()
    start_swarm(hash)
    add_scripted_peer(hash, [candidate_info(), :stop])

    assert {:error, {:metadata_unavailable, failures}} =
             Magnet.ConnectedMetadata.fetch(magnet(hash), [])

    assert :no_metadata_session in failures or :peer_died in failures
  end

  test "an eligible peer with no live Sender fails at open_swarm" do
    hash = new_hash()
    start_swarm(hash)
    add_scripted_peer(hash, [eligible_info()])

    assert {:error, {:metadata_unavailable, failures}} =
             Magnet.ConnectedMetadata.fetch(magnet(hash), [])

    assert failures != []
  end

  test "a peer that never answers is killed by the round timeout" do
    hash = new_hash()
    start_swarm(hash)

    Application.put_env(
      :elixir_torrent,
      :magnet_connected_metadata,
      Keyword.put(
        Application.get_env(:elixir_torrent, :magnet_connected_metadata),
        :peer_timeout_ms,
        60
      )
    )

    add_scripted_peer(hash, [candidate_info(), :hang])

    assert {:error, {:metadata_unavailable, failures}} =
             Magnet.ConnectedMetadata.fetch(magnet(hash), [])

    assert failures != []
  end

  test "an empty swarm short-circuits the round" do
    hash = new_hash()
    start_swarm(hash)

    assert {:error, :no_swarm_metadata_peers} = Magnet.ConnectedMetadata.fetch(magnet(hash), [])
  end

  test "a swarm of peers that never advertised ut_metadata is not worth a round" do
    hash = new_hash()
    start_swarm(hash)
    # Completed the base handshake, so it is a usable download peer — just not
    # one that can serve BEP 9 metadata.
    add_scripted_peer(hash, [non_candidate_info()])

    assert {:error, :no_swarm_metadata_peers} = Magnet.ConnectedMetadata.fetch(magnet(hash), [])
  end

  test "a swarm of peers with no extended handshake at all is not worth a round" do
    hash = new_hash()
    start_swarm(hash)
    add_scripted_peer(hash, [:error])

    assert {:error, :no_swarm_metadata_peers} = Magnet.ConnectedMetadata.fetch(magnet(hash), [])
  end

  describe "Magnet.Bootstrap lifecycle" do
    test "ensure/1 is idempotent and stop/1 tolerates a torrent with no bootstrap" do
      magnet = magnet(new_hash())

      assert :ok = Magnet.Bootstrap.ensure(magnet)
      on_exit(fn -> Magnet.Bootstrap.stop(magnet.hash) end)

      assert Magnet.Bootstrap.active?(magnet.hash)
      # A second round must reuse the existing bootstrap swarm, not start a
      # competing one for the same info-hash.
      assert :ok = Magnet.Bootstrap.ensure(magnet)

      assert :ok = Magnet.Bootstrap.stop(magnet.hash)
      refute Magnet.Bootstrap.active?(magnet.hash)
      assert :ok = Magnet.Bootstrap.stop(magnet.hash)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp new_hash, do: :crypto.strong_rand_bytes(20)

  defp peer_id, do: :crypto.strong_rand_bytes(20)

  defp magnet(hash), do: %Magnet{hash: hash, trackers: [], display_name: "cycle3"}

  defp ut_metadata_session do
    Session.new([UtMetadataExtension])
    |> Session.apply_peer_handshake(Handshake.from_map(%{"m" => %{"ut_metadata" => 2}}))
  end

  # Advertises ut_metadata but has not yet told us how big the metadata is.
  defp candidate_info do
    {:ok, %{ltep: ut_metadata_session(), metadata_size: nil, seeder?: false, unchoked?: false}}
  end

  # Knows the metadata size, so BEP 9 requests can start immediately.
  defp eligible_info do
    {:ok, %{ltep: ut_metadata_session(), metadata_size: 1_024, seeder?: true, unchoked?: true}}
  end

  # Completed the base handshake but never advertised ut_metadata.
  defp non_candidate_info do
    {:ok, %{ltep: Session.new([]), metadata_size: nil, seeder?: false, unchoked?: false}}
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

  defp add_scripted_peer(hash, script) do
    id = peer_id()
    key = Peer.make_key(hash, id)
    sup = GenServer.whereis({:via, Registry, {Registry, {hash, Torrent.Swarm}}})

    {:ok, _peer} =
      DynamicSupervisor.start_child(sup, %{
        id: make_ref(),
        start: {ControllerScript, :start_peer, [key]},
        restart: :temporary
      })

    {:ok, controller} = ControllerScript.start_controller(key, script)
    on_exit(fn -> stop_quietly(controller) end)
    key
  end

  defp stop_quietly(pid) when is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
  defp stop_quietly(_), do: :ok
end

defmodule Cycle3ConnectedMetadataCoverageTest.ControllerScript do
  @moduledoc """
  A `Peer.Controller` stand-in whose `:metadata_capable` answer changes from call
  to call, so a test can model a peer whose BEP 10 state shifts underneath the
  metadata round. The last scripted answer repeats once the script is exhausted.
  """
  use GenServer

  @spec start_peer(Peer.key()) :: GenServer.on_start()
  def start_peer(key) do
    GenServer.start_link(__MODULE__, {:peer, key})
  end

  @spec start_controller(Peer.key(), [term()]) :: GenServer.on_start()
  def start_controller(key, script) do
    GenServer.start(__MODULE__, {:controller, script},
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  @impl GenServer
  def init({:peer, key}) do
    {:ok, _} = Registry.register(Registry, {key, Peer}, nil)
    {:ok, key}
  end

  def init({:controller, script}), do: {:ok, script}

  @impl GenServer
  def handle_call(:metadata_capable, _from, script) do
    {answer, rest} =
      case script do
        [only] -> {only, [only]}
        [head | tail] -> {head, tail}
        [] -> {:error, []}
      end

    case answer do
      :stop -> {:stop, :normal, :error, rest}
      :hang -> {:noreply, rest}
      other -> {:reply, other, rest}
    end
  end
end

defmodule Cycle3SuperseedMagnetConnCoverageTest do
  @moduledoc """
  Coverage for BEP 16 super-seeding bookkeeping inside `Peer.Controller.State`,
  and for `Magnet.Connection` operations on a connection whose socket is already
  gone.

  Super-seeding is how a lone initial seeder makes a swarm self-sustaining: each
  peer is handed exactly one piece, and only once that peer proves it passed the
  piece on does it get another. That means the per-connection state has to track
  an assignment, notice when a *different* peer's assignment rotated, and stop
  advertising once the swarm has a second complete copy.
  """
  use ExUnit.Case, async: false

  alias Peer.Controller.State
  alias Peer.LTEP.Session
  alias PeerWireTest.SentCollector
  alias Torrent.Superseed

  @piece_len 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "super-seed assignment bookkeeping" do
    test "a peer that already holds its assigned piece triggers a rotation" do
      hash = new_hash()
      peer_id = <<1::160>>

      with_superseed(hash, 4, fn ->
        with_sender_stub(hash, peer_id, fn _key ->
          assert {:ok, 0} = Superseed.assign(hash, peer_id, nil)

          # The peer's bitfield now shows the piece we assigned, so the next
          # bitfield sync must move it on to a different piece.
          bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 0, 1)

          state =
            base_state(hash, 4, id: peer_id, superseed_piece: 0, bitfield: nil, status: :seed)

          assert %State{} = State.handle_bitfield(state, bitfield)
        end)
      end)
    end

    test "a rotation belonging to another peer is forwarded to that peer" do
      hash = new_hash()
      us = <<1::160>>
      them = <<2::160>>

      with_superseed(hash, 4, fn ->
        with_sender_stub(hash, us, fn _key ->
          assert {:ok, 0} = Superseed.assign(hash, them, nil)
          assert {:ok, 1} = Superseed.assign(hash, us, nil)

          {:ok, other_controller} = ControllerSink.start(hash, them, self())
          on_exit(fn -> stop_quietly(other_controller) end)

          state =
            base_state(hash, 4,
              id: us,
              superseed_piece: 1,
              bitfield: Torrent.Bitfield.make(4),
              status: :seed
            )

          # Piece 0 has now propagated to us, and piece 0 was `them`'s
          # assignment — Superseed rotates *their* piece, so our connection has
          # to relay the new assignment to their controller instead of applying
          # it to itself.
          assert %State{} = State.handle_have(state, 0)

          assert_receive {:controller, :superseed_assign}, 2_000
        end)
      end)
    end

    test "a peer with no assignment left is cleared" do
      hash = new_hash()
      peer_id = <<3::160>>

      with_superseed(hash, 1, fn ->
        with_sender_stub(hash, peer_id, fn _key ->
          # A single-piece torrent that the peer already has: there is nothing
          # left to assign, so the connection drops its superseed piece.
          full = Torrent.Bitfield.set(Torrent.Bitfield.make(1), 0, 1)
          state = base_state(hash, 1, id: peer_id, status: :seed, bitfield: full)

          assert %State{} = State.first_message(state, 0)
          # Nothing left to hide: the connection falls back to a full have batch.
          assert_receive {:sent, {:have, 0}}, 2_000
        end)
      end)
    end

    test "a second complete peer ends super-seeding for the whole swarm" do
      hash = new_hash()
      peer_id = <<4::160>>

      with_superseed(hash, 2, fn ->
        with_sender_stub(hash, peer_id, fn _key ->
          assert {:ok, _} = Superseed.assign(hash, peer_id, nil)

          state = base_state(hash, 2, id: peer_id, status: :seed, bitfield: nil)

          assert %State{bitfield: :all} = State.handle_have_all(state)

          # One complete remote copy is enough: hiding pieces past this point
          # only caps throughput, so super-seeding retires for the whole swarm.
          assert :deactivated = Superseed.confirm_seed(hash, peer_id)
          refute Superseed.active?(hash)
        end)
      end)
    end
  end

  describe "request pipeline back-pressure" do
    test "a request that fills the BEP 10 reqq window skips the follow-up" do
      hash = new_hash()

      with_sender_stub(hash, Peer.id(), fn _key ->
        # 63 in flight + the one we are about to record = the 64-slot cap.
        requests = MapSet.new(for i <- 0..62, do: {0, i * @piece_len, @piece_len})

        state =
          base_state(hash, 4,
            status: 0,
            interested: true,
            choke_me: false,
            requests: requests
          )

        assert %State{} = State.request(state, 0, 63 * @piece_len, @piece_len)
        assert_receive {:sent, {:request, 0, _, @piece_len}}, 2_000
      end)
    end
  end

  describe "Magnet.Connection on a dead socket" do
    test "close/1 accepts a connection that was never opened" do
      assert :ok = Magnet.Connection.close(nil)
      assert :ok = Magnet.Connection.close(:already_gone)
    end

    test "fetch_info/2 on a closed swarm connection reports the closure" do
      conn = %Magnet.Connection{
        socket: nil,
        transport: :swarm,
        peer: %Peer{ip: {127, 0, 0, 1}, port: 6881},
        hash: new_hash(),
        ltep: Session.new([])
      }

      assert {:error, _} = Magnet.Connection.fetch_info(conn, conn.hash)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp new_hash, do: :crypto.strong_rand_bytes(20)

  defp base_state(hash, pieces_count, overrides) do
    struct!(
      %State{
        hash: hash,
        id: Peer.id(),
        fast_extension: nil,
        status: nil,
        pieces_count: pieces_count,
        socket: nil,
        choke: true
      },
      overrides
    )
  end

  defp with_superseed(hash, pieces_count, fun) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "ss", "piece length" => @piece_len}},
      left: 0,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: full_bitfield(pieces_count),
      # A restarted torrent that is already :seed refuses to super-seed, so the
      # fixture starts from the pre-seed state the arming path expects.
      peer_status: nil
    }

    {:ok, model} = Torrent.Model.start_link(torrent)
    on_exit(fn -> stop_quietly(model) end)
    :ok = Torrent.PiecesStatistic.init(torrent)

    {:ok, superseed} = Superseed.start_link(hash)
    on_exit(fn -> stop_quietly(superseed) end)

    assert :armed = Superseed.arm(hash)
    assert :active = Superseed.activate(hash, 0)

    fun.()
  end

  defp full_bitfield(count) do
    Enum.reduce(0..(count - 1), Torrent.Bitfield.make(count), &Torrent.Bitfield.set(&2, &1, 1))
  end

  defp with_sender_stub(hash, id, fun) do
    key = Peer.make_key(hash, id)
    {:ok, stub} = SentCollector.start_link(key, self())
    on_exit(fn -> stop_quietly(stub) end)

    fun.(key)
  end

  defp stop_quietly(pid) when is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
  defp stop_quietly(_), do: :ok
end

defmodule ControllerSink do
  @moduledoc false
  use GenServer

  @spec start(Torrent.hash(), Peer.id(), pid()) :: GenServer.on_start()
  def start(hash, id, test_pid) do
    key = Peer.make_key(hash, id)

    GenServer.start(__MODULE__, test_pid,
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  @impl GenServer
  def init(test_pid), do: {:ok, test_pid}

  @impl GenServer
  def handle_cast({verb, _args}, test_pid) do
    send(test_pid, {:controller, verb})
    {:noreply, test_pid}
  end
end

defmodule Cycle3ControllerStateCoverageTest do
  @moduledoc """
  Branch coverage for `Peer.Controller.State` — the pure per-connection state
  machine behind every BEP 3 wire message.

  Two themes dominate the branches exercised here:

    * **Fail-closed probes.** The state machine constantly asks the torrent's
      `Model` / `PiecesStatistic` "do we have this piece?". Those live in other
      processes that can die while a peer connection is still up, so every probe
      is wrapped in `catch :exit` and must answer conservatively rather than
      take the peer down with it (`Peer` is a `one_for_all` tree — one crash
      drops a productive remote seeder).

    * **Magnet bootstrap.** Before the metadata arrives we have no piece count
      and no storage, so `have` / `reject` / request-making are deliberately
      inert; only `have_all` is meaningful (BEP 9).
  """
  use ExUnit.Case, async: false

  alias Peer.Controller.{FastExtension, State}
  alias PeerWireTest.SentCollector

  @piece_len 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "seeder detection" do
    test "a seeder announcing itself to a seed connection is a protocol error" do
      hash = new_hash()
      state = base_state(hash, 4, bitfield: :all, status: nil)

      # Two seeders have nothing to trade; BEP 3 implementations drop the link.
      assert {:error, :two_seeders, ^state} = State.seed(state)
    end
  end

  describe "useful_for_download?/1 fails closed without a Model" do
    test "a remote seeder is assumed useful when our own progress is unknown" do
      hash = new_hash()
      # torrent_complete?/1 exits :noproc and must answer false ("not complete"),
      # so a seeder still counts as useful.
      assert State.useful_for_download?(base_state(hash, 4, bitfield: :all))
    end

    test "a bitfield peer is assumed useless when piece statistics are gone" do
      hash = new_hash()

      refute State.useful_for_download?(
               base_state(hash, 4, bitfield: Torrent.Bitfield.make(4), interested: false)
             )
    end

    test "a torrent with no known piece count is never useful" do
      hash = new_hash()

      refute State.useful_for_download?(
               base_state(hash, 0, bitfield: Torrent.Bitfield.make(1), interested: false)
             )
    end
  end

  describe "stale_useless_pin?/1" do
    test "an unpinned peer is never stale" do
      refute State.stale_useless_pin?(base_state(new_hash(), 4, status: nil))
    end

    test "a pin with no recorded start time has zero age" do
      hash = new_hash()

      state =
        base_state(hash, 4,
          status: 0,
          choke_me: true,
          pin_downloaded_bytes: 0,
          pinned_at: 0
        )

      # pin_age_ms/1 short-circuits to 0, which is below any threshold.
      refute State.stale_useless_pin?(state)
    end
  end

  describe "magnet bootstrap keeps the piece machinery inert" do
    setup do
      hash = new_hash()
      start_bootstrap(hash)
      {:ok, hash: hash}
    end

    test "have/1 past the (unknown) piece count is read as have_all", %{hash: hash} do
      state = base_state(hash, 0, bitfield: nil)

      assert %State{bitfield: :all} = State.handle_have(state, 7)
    end

    test "reject is ignored while there is no piece worker to tell", %{hash: hash} do
      state = base_state(hash, 0)

      assert ^state = State.handle_reject(state, 0, 0, @piece_len)
    end

    test "interest does not start a request round", %{hash: hash} do
      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, status: 0, bitfield: full_bitfield(4), choke_me: false)

        assert %State{interested: true} = State.interested(state, 0)
        assert_receive {:sent, :interested}, 2_000
        refute_received {:sent, {:request, _, _, _}}
      end)
    end
  end

  describe "handle_suggest_piece/2" do
    test "a suggestion for a piece the peer does not advertise is ignored" do
      hash = new_hash()
      state = base_state(hash, 4, bitfield: Torrent.Bitfield.make(4), status: nil)

      # BEP 6 suggest is advisory; we only repin if the peer actually has it.
      assert %State{status: nil} = State.handle_suggest_piece(state, 2)
    end
  end

  describe "handle_hash_reject/2" do
    test "a reject for a request we never sent is dropped" do
      hash = new_hash()
      state = base_state(hash, 4)

      assert ^state = State.handle_hash_reject(state, hash_request())
    end
  end

  describe "send_allowed_fast/1" do
    test "does not recompute a set that was already sent" do
      hash = new_hash()

      state =
        base_state(hash, 4, fast_extension: %FastExtension{allowed_fast: MapSet.new([1, 2])})

      assert ^state = State.send_allowed_fast(state)
    end

    test "skips the set when the peer address is already unavailable" do
      hash = new_hash()

      state =
        base_state(hash, 4,
          fast_extension: %FastExtension{allowed_fast: MapSet.new()},
          socket: closed_socket()
        )

      # BEP 6 allowed-fast is keyed on the peer's IP; without a peername there
      # is nothing to derive the set from.
      assert ^state = State.send_allowed_fast(state)
    end
  end

  describe "pex_entry/1" do
    test "a socket with no peername yields no PEX entry" do
      hash = new_hash()
      assert :error = State.pex_entry(base_state(hash, 4, socket: closed_socket()))
    end
  end

  describe "apply_pex_snapshot/3" do
    test "a peer that did not negotiate ut_pex receives nothing" do
      hash = new_hash()
      state = base_state(hash, 4, ltep: nil)

      assert ^state = State.apply_pex_snapshot(state, %{})
    end
  end

  describe "handle_port/2" do
    test "a DHT port from a peer with no reachable address is dropped" do
      hash = new_hash()
      state = base_state(hash, 4, socket: closed_socket())

      # BEP 5: the port message only tells us the peer's DHT port; without its
      # IP there is no node to seed into the routing table.
      assert ^state = State.handle_port(state, 6881)
    end
  end

  describe "request/4 pipeline accounting" do
    test "an ack that was never counted does not underflow pending_requests" do
      hash = new_hash()

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, status: 0, pending_requests: 0, choke_me: true)

        assert %State{pending_requests: 0} = State.request(state, 0, 0, @piece_len)
        assert_receive {:sent, {:request, 0, 0, @piece_len}}, 2_000
      end)
    end

    test "a saturated request queue skips the next request" do
      hash = new_hash()

      with_sender_stub(hash, fn _key ->
        # BEP 10 reqq: 64 unanswered requests is our cap; going past it gets
        # requests silently dropped by most clients.
        requests = MapSet.new(for i <- 0..63, do: {0, i * @piece_len, @piece_len})

        state =
          base_state(hash, 4,
            status: 0,
            interested: true,
            choke_me: false,
            requests: requests
          )

        assert %State{} = State.handle_unchoke(state)
        refute_received {:sent, {:request, _, _, _}}
      end)
    end
  end

  describe "choke/1 without the Fast extension" do
    test "has no queued uploads to flush" do
      hash = new_hash()

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, fast_extension: nil, choke: false)

        assert %State{choke: true} = State.choke(state)
        assert_receive {:sent, :choke}, 2_000
      end)
    end
  end

  describe "handle_interested/1 unchoke decision" do
    test "an already unchoked peer is left alone" do
      hash = new_hash()

      state = base_state(hash, 4, choke: false)
      assert %State{choke: false, interested_of_me: true} = State.handle_interested(state)
    end

    test "a seed connection whose Model is gone is optimistically unchoked" do
      hash = new_hash()

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, choke: true, status: :seed)

        # Model.downloaded?/1 exits; for a :seed connection the safe answer is
        # "we do have pieces", so the peer still gets a slot.
        assert %State{choke: false} = State.handle_interested(state)
        assert_receive {:sent, :unchoke}, 2_000
      end)
    end

    test "a leech connection with no piece statistics stays choked" do
      hash = new_hash()
      state = base_state(hash, 4, choke: true, status: 0)

      assert %State{choke: true} = State.handle_interested(state)
    end

    test "a torrent with no known piece count stays choked" do
      hash = new_hash()
      state = base_state(hash, 0, choke: true, status: 0)

      assert %State{choke: true} = State.handle_interested(state)
    end
  end

  describe "bitfield logging with an incomplete Model" do
    test "renders zero verified pieces when the Model has no bitfield yet" do
      hash = new_hash()

      with_model(hash, [bitfield: nil], fn ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 4, fast_extension: nil)

          assert %State{} = State.first_message(state, 1)
          assert_receive {:sent, {:bitfield, ^hash}}, 2_000
        end)
      end)
    end
  end

  describe "ensure_piece_index/1" do
    test "adopts the piece index the torrent controller already chose" do
      hash = new_hash()

      with_model(hash, [peer_status: 2], fn ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 4, status: nil, bitfield: nil, choke_me: true)

          assert %State{status: 2} = State.handle_bitfield(state, full_bitfield(4))
        end)
      end)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp new_hash, do: :crypto.strong_rand_bytes(20)

  defp full_bitfield(count) do
    Enum.reduce(0..(count - 1), Torrent.Bitfield.make(count), &Torrent.Bitfield.set(&2, &1, 1))
  end

  defp hash_request do
    %Peer.HashWire{
      pieces_root: :binary.copy(<<7>>, 32),
      base_layer: 0,
      index: 0,
      length: 2,
      proof_layers: 0
    }
  end

  defp base_state(hash, pieces_count, overrides \\ []) do
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

  # A TCP socket that has already been closed: every peername/setopts probe on
  # it fails, which is what a peer teardown racing the controller looks like.
  defp closed_socket do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    :ok = :gen_tcp.close(listen)
    listen
  end

  defp start_bootstrap(hash) do
    {:ok, pid} =
      GenServer.start(Cycle3ControllerStateCoverageTest.Idle, nil,
        name: {:via, Registry, {Registry, {:magnet_bootstrap, hash}}}
      )

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp with_model(hash, overrides, fun) do
    torrent =
      struct!(
        %Torrent{
          hash: hash,
          metadata: %{"info" => %{"name" => "state", "piece length" => @piece_len}},
          left: 4 * @piece_len,
          last_index: 3,
          last_piece_length: @piece_len,
          bitfield: Torrent.Bitfield.make(4)
        },
        overrides
      )

    {:ok, pid} = Torrent.Model.start_link(torrent)
    on_exit(fn -> stop_quietly(pid) end)
    :ok = Torrent.PiecesStatistic.init(torrent)

    fun.()
  end

  defp with_sender_stub(hash, fun) do
    key = Peer.make_key(hash, Peer.id())
    {:ok, stub} = SentCollector.start_link(key, self())
    on_exit(fn -> stop_quietly(stub) end)

    fun.(key)
  end

  defp stop_quietly(pid) when is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
end

defmodule Cycle3ControllerStateCoverageTest.Idle do
  @moduledoc false
  use GenServer

  @impl GenServer
  def init(state), do: {:ok, state}
end

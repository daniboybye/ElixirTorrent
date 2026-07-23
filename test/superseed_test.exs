defmodule SuperseedTest do
  use ExUnit.Case, async: false

  alias Peer.Controller.State
  alias Torrent.Superseed

  @piece_length 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "state machine activates once, assigns rare pieces, rotates, and finishes" do
    hash = :crypto.strong_rand_bytes(20)

    with_torrent(hash, 4, fn ->
      refute Superseed.active?(hash)
      assert :inactive = Superseed.activate(hash, 1)
      assert :armed = Superseed.arm(hash)
      assert :active = Superseed.activate(hash, 0)
      assert Superseed.active?(hash)

      peer_a = <<1::160>>
      peer_b = <<2::160>>

      assert {:ok, 0} = Superseed.assign(hash, peer_a, nil)
      assert {:ok, 1} = Superseed.assign(hash, peer_b, nil)
      assert {:rotate, ^peer_a, 2} = Superseed.peer_have(hash, peer_a, 0)

      assert :deactivated = Superseed.confirm_seed(hash, peer_b)
      refute Superseed.active?(hash)
      assert :inactive = Superseed.activate(hash, 0)
    end)
  end

  test "piece picker prefers never-advertised rare pieces and excludes peer holdings" do
    availability = [{0, 0}, {1, 2}, {2, 0}, {3, 1}]

    assert Superseed.pick_piece(
             availability,
             MapSet.new([0]),
             MapSet.new([2]),
             MapSet.new([0, 1])
           ) == 3

    assert Superseed.pick_piece(
             availability,
             MapSet.new([0]),
             MapSet.new([2]),
             MapSet.new([0, 1, 2, 3])
           ) == 3
  end

  test "armed completion stays normal when another seed is already confirmed" do
    hash = :crypto.strong_rand_bytes(20)

    with_torrent(hash, 2, fn ->
      assert :armed = Superseed.arm(hash)
      assert :inactive = Superseed.activate(hash, 1)
      refute Superseed.active?(hash)
      assert :inactive = Superseed.activate(hash, 0)
    end)
  end

  test "new seed connection receives one fabricated have while active" do
    hash = :crypto.strong_rand_bytes(20)

    with_torrent(hash, 3, fn ->
      assert :armed = Superseed.arm(hash)
      assert :active = Superseed.activate(hash, 0)

      with_sender(hash, fn id ->
        state = base_state(hash, id, 3, status: :seed)

        assert %State{superseed_piece: 0} = State.first_message(state, 0)
        assert_receive {:sent, {:have, 0}}
        refute_received {:sent, :have_all}
        refute_received {:sent, {:bitfield, ^hash}}
      end)
    end)
  end

  test "already-connected peer receives one fabricated have on seed transition" do
    hash = :crypto.strong_rand_bytes(20)

    with_torrent(hash, 3, fn ->
      assert :armed = Superseed.arm(hash)
      assert :active = Superseed.activate(hash, 0)

      with_sender(hash, fn id ->
        state = base_state(hash, id, 3, status: 1, interested: true)

        assert %State{status: :seed, interested: false, superseed_piece: 0} =
                 State.seed(state)

        assert_receive {:sent, :not_interested}
        assert_receive {:sent, {:have, 0}}
        refute_received {:sent, :have_all}
      end)
    end)
  end

  test "seed transition does not assign a piece the connected peer already has" do
    hash = :crypto.strong_rand_bytes(20)

    with_torrent(hash, 3, fn ->
      assert :armed = Superseed.arm(hash)
      assert :active = Superseed.activate(hash, 0)

      with_sender(hash, fn id ->
        bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(3), 0, 1)
        state = base_state(hash, id, 3, status: 2, bitfield: bitfield)

        assert %State{superseed_piece: 1, bitfield: ^bitfield} = State.seed(state)
        assert_receive {:sent, {:have, 1}}
      end)
    end)
  end

  test "peer with no next assignment falls back to have_all" do
    hash = :crypto.strong_rand_bytes(20)

    with_torrent(hash, 2, fn ->
      assert :armed = Superseed.arm(hash)
      assert :active = Superseed.activate(hash, 0)

      with_sender(hash, fn id ->
        state = base_state(hash, id, 2, status: :seed)
        assert %State{superseed_piece: 0} = state = State.first_message(state, 0)
        assert_receive {:sent, {:have, 0}}

        other_peer = <<7::160>>
        assert {:ok, 1} = Superseed.assign(hash, other_peer, nil)

        assert %State{superseed_piece: :all} = State.handle_have(state, 0)
        assert_receive {:sent, :have_all}
      end)
    end)
  end

  test "requests for hidden pieces are rejected with the Fast extension" do
    hash = :crypto.strong_rand_bytes(20)

    with_torrent(hash, 2, fn ->
      assert :armed = Superseed.arm(hash)
      assert :active = Superseed.activate(hash, 0)

      with_sender(hash, fn id ->
        state =
          base_state(hash, id, 2,
            status: :seed,
            superseed_piece: 0,
            fast_extension: %Peer.Controller.FastExtension{}
          )

        assert %State{} = State.handle_request(state, 1, 0, @piece_length)
        assert_receive {:sent, {:reject, 1, 0, @piece_length}}
      end)
    end)
  end

  defp with_torrent(hash, pieces_count, fun) do
    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "superseed-test", "piece length" => @piece_length}},
      left: 0,
      last_index: pieces_count - 1,
      last_piece_length: @piece_length,
      bitfield:
        Enum.reduce(0..(pieces_count - 1), Torrent.Bitfield.make(pieces_count), fn index, acc ->
          Torrent.Bitfield.set(acc, index, 1)
        end),
      peer_status: :seed
    }

    {:ok, model} = Torrent.Model.start_link(torrent)
    :ok = Torrent.PiecesStatistic.init(torrent)
    {:ok, superseed} = Superseed.start_link(hash)

    on_exit(fn ->
      stop_quietly(superseed)
      stop_quietly(model)
    end)

    fun.()
  end

  defp with_sender(hash, fun) do
    id = :crypto.strong_rand_bytes(20)
    key = Peer.make_key(hash, id)
    {:ok, sender} = SuperseedTest.SenderStub.start_link(key, self())
    on_exit(fn -> stop_quietly(sender) end)
    fun.(id)
  end

  defp base_state(hash, id, pieces_count, overrides) do
    struct!(
      %State{
        hash: hash,
        id: id,
        fast_extension: nil,
        status: nil,
        pieces_count: pieces_count,
        socket: nil
      },
      overrides
    )
  end

  defp stop_quietly(pid) do
    try do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end
end

defmodule SuperseedTest.SenderStub do
  use GenServer

  def start_link(key, test_pid) do
    GenServer.start_link(__MODULE__, test_pid,
      name: {:via, Registry, {Registry, {key, Peer.Sender}}}
    )
  end

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_cast(message, test_pid) do
    send(test_pid, {:sent, message})
    {:noreply, test_pid}
  end
end

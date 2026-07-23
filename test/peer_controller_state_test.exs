defmodule PeerControllerStateTest do
  use ExUnit.Case, async: false

  alias Peer.Controller.State
  alias PeerWireTest.SentCollector

  @piece_len 16_384

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "first_message/2 startup branches" do
    test "seed with Fast sends have_all" do
      hash = :crypto.strong_rand_bytes(20)

      with_sender_stub(hash, fn _key ->
        state =
          base_state(hash, 4, status: :seed, fast_extension: %Peer.Controller.FastExtension{})

        assert %State{} = State.first_message(state, 0)
        assert_receive {:sent, :have_all}
      end)
    end

    test "seed without Fast sends bitfield" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4, left: 0), fn _ ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 4, status: :seed)

          assert %State{} = State.first_message(state, 0)
          assert_receive {:sent, {:bitfield, ^hash}}
        end)
      end)
    end

    test "leech with Fast at downloaded 0 sends bitfield not have_none" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          state =
            base_state(hash, 4, status: 0, fast_extension: %Peer.Controller.FastExtension{})

          assert %State{} = State.first_message(state, 0)
          assert_receive {:sent, {:bitfield, ^hash}}
          refute_received {:sent, :have_none}
        end)
      end)
    end
  end

  describe "have/2 and handle_have/2" do
    test "have/2 skips wire when we already advertise the piece" do
      hash = :crypto.strong_rand_bytes(20)
      bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 1, 1)

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, 4, bitfield: bitfield)
        assert %State{} = State.have(state, 1)
        refute_received {:sent, _}
      end)
    end

    test "handle_have on nil bitfield bootstraps then sets the bit" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, bitfield: nil, status: 0)

        new_state = State.handle_have(state, 2)
        assert %State{bitfield: bf} = new_state
        assert State.has_index?(new_state, 2)
        assert bf != nil
      end)
    end

    test "handle_have on :all is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, bitfield: :all)

      assert {:error, :protocol_error, ^state} = State.handle_have(state, 0)
    end

    test "duplicate handle_have is a no-op" do
      hash = :crypto.strong_rand_bytes(20)
      bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 0, 1)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, bitfield: bitfield, status: 0)
        assert ^state = State.handle_have(state, 0)
      end)
    end
  end

  describe "handle_bitfield/2" do
    test "valid bitfield updates availability and pins a piece" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.set(Torrent.Bitfield.make(4), 2, 1)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4, status: nil)

        assert %State{bitfield: ^bf, status: status} = State.handle_bitfield(state, bf)
        assert is_integer(status)
      end)
    end

    test "second bitfield is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      bf = Torrent.Bitfield.make(4)
      state = base_state(hash, 4, bitfield: bf)

      assert {:error, :protocol_error, ^state} = State.handle_bitfield(state, bf)
    end

    test "seed peer ignores inbound bitfield" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, status: :seed, bitfield: nil)
      assert ^state = State.handle_bitfield(state, Torrent.Bitfield.make(4))
    end

    test "invalid bitfield size is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        state = base_state(hash, 4)
        assert {:error, :protocol_error, ^state} = State.handle_bitfield(state, <<0, 0>>)
      end)
    end
  end

  describe "Fast extension have_all / have_none" do
    test "handle_have_all marks peer as :all and unchokes for download" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        with_sender_stub(hash, fn _key ->
          state = base_state(hash, 4, status: 0, interested: false)

          assert %State{bitfield: :all, choke: false} = State.handle_have_all(state)
        end)
      end)
    end

    test "handle_have_all while seeding is two_seeders error" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, status: :seed)

      assert {:error, :two_seeders, ^state} = State.handle_have_all(state)
    end

    test "handle_have_none on leech sets :none" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, status: 0)
      assert %State{bitfield: :none} = State.handle_have_none(state)
    end

    test "handle_have_none with existing bitfield is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, bitfield: Torrent.Bitfield.make(4))

      assert {:error, :protocol_error, ^state} = State.handle_have_none(state)
    end
  end

  describe "disconnect_operations/1 and eviction helpers" do
    test "disconnect flushes cancels, not_interested, and choke" do
      hash = :crypto.strong_rand_bytes(20)

      with_sender_stub(hash, fn _key ->
        state =
          base_state(hash, 4,
            interested: true,
            choke: false,
            requests: MapSet.new([{0, 0, @piece_len}])
          )

        {ops, _state} = State.disconnect_operations(state)

        assert {:cancel, 0, 0, @piece_len} in ops
        assert :not_interested in ops
        assert :choke in ops
      end)
    end

    test "eviction_info and useful_for_download? branches" do
      hash = :crypto.strong_rand_bytes(20)
      now = System.monotonic_time(:millisecond)

      with_model(sample_torrent(hash, 4, left: 0), fn _ ->
        idle =
          base_state(hash, 4,
            bitfield: :none,
            connected_at: now - 5_000,
            last_block_at: now - 1_000
          )

        info = State.eviction_info(idle)
        assert info.downloaded_bytes == 0
        assert info.age_ms >= 5_000
        assert info.idle_ms >= 1_000
        refute info.useful?
        refute info.seeder?

        all = %{idle | bitfield: :all}
        assert State.eviction_info(all).seeder?
        refute State.useful_for_download?(all)

        interested = %{idle | bitfield: nil, interested: true}
        assert State.useful_for_download?(interested)
      end)
    end

    test "rank/1 returns tuple only when peer is interested in us" do
      hash = :crypto.strong_rand_bytes(20)
      id = <<3::160>>

      state =
        base_state(hash, 4, id: id, rank: 42, interested_of_me: true)

      assert State.rank(state) == {42, id}
      refute State.rank(%{state | interested_of_me: false})
    end

    test "stale_useless_pin? detects choked zero-byte pins" do
      hash = :crypto.strong_rand_bytes(20)
      now = System.monotonic_time(:millisecond)

      state =
        base_state(hash, 4,
          status: 0,
          choke_me: true,
          pin_downloaded_bytes: 0,
          pinned_at: now - 25_000
        )

      assert State.stale_useless_pin?(state)
      refute State.stale_useless_pin?(%{state | pin_downloaded_bytes: 1})
    end
  end

  describe "reject, cancel, and piece accounting" do
    test "handle_reject clears matching in-flight request" do
      hash = :crypto.strong_rand_bytes(20)

      with_model(sample_torrent(hash, 4), fn _ ->
        {:ok, piece_pid} = start_piece_worker(hash, 0)
        _peer = ensure_peer_registered(hash)

        on_exit(fn -> stop_worker(piece_pid) end)

        state =
          base_state(hash, 4,
            status: 0,
            interested: true,
            choke_me: false,
            requests: MapSet.new([{0, 0, @piece_len}])
          )

        assert %State{requests: reqs} = State.handle_reject(state, 0, 0, @piece_len)
        assert MapSet.size(reqs) == 0
      end)
    end

    test "handle_reject for unknown request is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      state = base_state(hash, 4, requests: MapSet.new())

      assert {:error, :protocol_error, ^state} =
               State.handle_reject(state, 0, 0, @piece_len)
    end

    test "handle_piece without matching request is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          status: 0,
          requests: MapSet.new([{0, 0, @piece_len}])
        )

      assert {:error, :protocol_error, ^state} =
               State.handle_piece(state, 0, @piece_len, @piece_len)
    end

    test "handle_piece with matching request updates counters" do
      hash = :crypto.strong_rand_bytes(20)

      state =
        base_state(hash, 4,
          status: 0,
          requests: MapSet.new([{0, 0, @piece_len}]),
          rank: 0,
          downloaded_bytes: 0
        )

      assert %State{
               rank: @piece_len,
               downloaded_bytes: @piece_len,
               requests: reqs
             } = State.handle_piece(state, 0, 0, @piece_len)

      assert MapSet.size(reqs) == 0
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count, opts \\ []) do
    left = Keyword.get(opts, :left, pieces_count * @piece_len)

    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => @piece_len}},
      left: left,
      last_index: pieces_count - 1,
      last_piece_length: @piece_len,
      bitfield: Torrent.Bitfield.make(pieces_count),
      peer_status: nil
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

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      try do
        if Process.alive?(model_pid), do: GenServer.stop(model_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
  end

  defp with_sender_stub(hash, fun) do
    id = Peer.id()
    key = Peer.make_key(hash, id)

    {:ok, stub} =
      SentCollector.start_link(key, self())

    on_exit(fn ->
      try do
        if Process.alive?(stub), do: GenServer.stop(stub, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)

    fun.(key)
  end

  defp start_piece_worker(hash, index) do
    name = {:via, Registry, {Registry, {{index, hash}, Torrent.Downloads.Piece}}}

    GenServer.start(Torrent.Downloads.Piece, {hash, index}, name: name)
  end

  defp ensure_peer_registered(hash) do
    key = Peer.make_key(hash, Peer.id())
    via = {:via, Registry, {Registry, {key, Peer}}}

    case GenServer.whereis(via) do
      nil ->
        {:ok, pid} = PeerControllerStateTest.DummyPeer.start_link(via)
        pid

      pid ->
        pid
    end
  end

  defp stop_quietly(pid) do
    try do
      if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
    catch
      :exit, _ -> :ok
    end
  end

  defp stop_worker(pid), do: stop_quietly(pid)
end

defmodule PeerControllerStateTest.DummyPeer do
  @moduledoc false
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl true
  def init(_), do: {:ok, nil}
end

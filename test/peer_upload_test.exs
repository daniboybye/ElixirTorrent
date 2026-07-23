defmodule PeerUploadTest do
  use ExUnit.Case, async: false

  alias Peer.Controller.State

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  defp sample_torrent(hash, last_index, attrs \\ []) do
    pieces_count = last_index + 1
    bitfield = Torrent.Bitfield.make(pieces_count)

    struct!(
      %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "test", "piece length" => 16_384}},
        left: pieces_count * 16_384,
        last_index: last_index,
        last_piece_length: 16_384,
        bitfield: bitfield,
        peer_status: nil
      },
      attrs
    )
  end

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Torrent.Model.start_link(torrent)

    on_exit(fn ->
      # GenServer.stop on an already-dying process raises an exit, not an
      # exception — rescue never caught it.
      try do
        if Process.alive?(model_pid), do: GenServer.stop(model_pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent)
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

  test "handle_interested optimistically unchokes when we offer pieces" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 4
    bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(pieces_count), 1, 1)
    torrent = sample_torrent(hash, pieces_count - 1, bitfield: bitfield, left: 3 * 16_384)

    with_model(torrent, fn _ ->
      :ok = Torrent.PiecesStatistic.set(hash, 1, :complete)

      state = base_state(hash, pieces_count)

      refute state.choke == false
      new_state = State.handle_interested(state)

      assert new_state.interested_of_me
      refute new_state.choke
    end)
  end

  test "handle_interested stays choked when we have no pieces" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 4
    torrent = sample_torrent(hash, pieces_count - 1)

    with_model(torrent, fn _ ->
      state = base_state(hash, pieces_count)
      new_state = State.handle_interested(state)

      assert new_state.interested_of_me
      assert new_state.choke
    end)
  end

  test "seed transition advertises have_all to the peer" do
    hash = :crypto.strong_rand_bytes(20)
    id = <<2::160>>
    key = Peer.make_key(hash, id)
    pieces_count = 4
    torrent = sample_torrent(hash, pieces_count - 1, peer_status: :seed, left: 0)

    with_model(torrent, fn _ ->
      {:ok, sender_pid} =
        GenServer.start_link(
          Peer.SenderStub,
          {key, self()},
          name: {:via, Registry, {Registry, {key, Peer.Sender}}}
        )

      on_exit(fn ->
        if Process.alive?(sender_pid), do: GenServer.stop(sender_pid, :normal, 1_000)
      end)

      state =
        base_state(hash, pieces_count,
          id: id,
          status: 0,
          interested: true
        )

      assert %State{status: :seed, interested: false} = State.seed(state)
      assert_receive {:sent, :not_interested}
      assert_receive {:sent, :have_all}
    end)
  end

  test "send_allowed_fast uses Peer.Transport.safe_peername for uTP sockets" do
    source = File.read!(Path.expand("../lib/elixir_torrent/peer/controller/state.ex", __DIR__))

    assert source =~ "Peer.Transport.safe_peername(state.socket)"
    refute source =~ ":inet.peername(state.socket)"
  end

  test "productive disconnect re-offers endpoint before ConnectionManager.kick" do
    source = File.read!(Path.expand("../lib/elixir_torrent/peer/controller.ex", __DIR__))

    assert source =~ "Peer.DialBackoff.mark_productive(state.hash, ip, port)"
    assert source =~ "Peer.ConnectionManager.offer_peers(state.hash, [%Peer{ip: ip, port: port}])"
    assert source =~ "Peer.ConnectionManager.kick(state.hash)"
    # kick-alone is a no-op when dial_done already removed the peer from the queue.
    refute source =~ ~r/mark_productive\(state\.hash, ip, port\)\s*\n\s*Peer\.ConnectionManager\.kick/
  end

  test "handle_request stays choked without serving when peer is choked" do
    hash = :crypto.strong_rand_bytes(20)
    pieces_count = 1
    bitfield = Torrent.Bitfield.set(Torrent.Bitfield.make(pieces_count), 0, 1)

    torrent =
      sample_torrent(hash, 0,
        bitfield: bitfield,
        left: 0,
        downloaded: 16_384
      )

    with_model(torrent, fn _ ->
      :ok = Torrent.PiecesStatistic.set(hash, 0, :complete)

      state =
        base_state(hash, pieces_count,
          choke: true,
          status: :seed
        )

      assert %State{choke: true} = State.handle_request(state, 0, 0, 16_384)
    end)
  end
end

defmodule Peer.SenderStub do
  use GenServer

  def init({key, test_pid}), do: {:ok, {key, test_pid}}

  def handle_cast(:have_all, {key, test_pid}) do
    send(test_pid, {:sent, :have_all})
    {:noreply, {key, test_pid}}
  end

  def handle_cast(:not_interested, {key, test_pid}) do
    send(test_pid, {:sent, :not_interested})
    {:noreply, {key, test_pid}}
  end

  def handle_cast(_msg, state), do: {:noreply, state}
end

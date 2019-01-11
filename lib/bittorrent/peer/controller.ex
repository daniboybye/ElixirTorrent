defmodule Peer.Controller do
  use GenServer
  use Via

  require Logger

  alias __MODULE__.{State, FastExtension}
  alias Peer.Sender
  alias Torrent.{Uploader, Downloads}

  import Peer, only: [make_key: 2, key_to_id: 1, key_to_hash: 1]

  # @spec start_link({Peer.id(), Torrent.hash(), port(), Peer.reserved()}) :: GenServer.on_start()
  def start_link([hash, id, socket, reserved]) do
    GenServer.start_link(
      __MODULE__,
      [hash, id, socket, reserved],
      name: via(make_key(hash, id))
    )
  end

  @spec have(Peer.key(), Torrent.index()) :: :ok
  def have(key, index), do: GenServer.cast(via(key), {:have, [index]})

  @spec interested(Peer.key(), Torrent.index()) :: :ok
  def interested(key, index),
    do: GenServer.cast(via(key), {:interested, [index]})

  @spec cancel(Torrent.hash(), Peer.id(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          :ok
  def cancel(hash, id, index, begin, length) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:cancel, [index, begin, length]})
  end

  @spec seed(Peer.key()) :: :ok
  def seed(key), do: GenServer.cast(via(key), {:seed, []})

  @spec choke(Torrent.hash(), Peer.id()) :: :ok
  def choke(hash, id) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:choke, []})
  end

  @spec unchoke(Torrent.hash(), Peer.id()) :: :ok
  def unchoke(hash, id) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:unchoke, []})
  end

  @spec rank(Peer.key()) :: State.rank()
  def rank(key), do: GenServer.call(via(key), :rank)

  @spec reset_rank(Peer.key()) :: :ok
  def reset_rank(key), do: GenServer.cast(via(key), {:reset_rank, []})

  @spec handle_choke(Peer.key()) :: :ok
  def handle_choke(key), do: GenServer.cast(via(key), {:handle_choke, []})

  @spec handle_unchoke(Peer.key()) :: :ok
  def handle_unchoke(key), do: GenServer.cast(via(key), {:handle_unchoke, []})

  @spec handle_interested(Peer.key()) :: :ok
  def handle_interested(key),
    do: GenServer.cast(via(key), {:handle_interested, []})

  @spec handle_not_interested(Peer.key()) :: :ok
  def handle_not_interested(key),
    do: GenServer.cast(via(key), {:handle_not_interested, []})

  @spec handle_have(Peer.key(), Torrent.index()) :: :ok
  def handle_have(key, index),
    do: GenServer.cast(via(key), {:handle_have, [index]})

  @spec handle_bitfield(Peer.key(), Torrent.bitfield()) :: :ok
  def handle_bitfield(key, bitfield),
    do: GenServer.cast(via(key), {:handle_bitfield, [bitfield]})

  @spec handle_request(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_request(key, index, begin, length) do
    GenServer.cast(via(key), {:handle_request, [index, begin, length]})
  end

  @spec handle_piece(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def handle_piece(key, index, begin, block) do
    Downloads.response(key_to_hash(key), index, key_to_id(key), begin, block)
    GenServer.cast(via(key), {:handle_piece, [index, begin, byte_size(block)]})
  end

  @spec handle_cancel(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_cancel(key, index, begin, length) do
    Uploader.cancel(key_to_hash(key), key_to_id(key), index, begin, length)
  end

  @spec handle_port(Peer.key(), :inet.port_number()) :: :ok
  def handle_port(key, port),
    do: GenServer.cast(via(key), {:handle_port, [port]})

  @spec handle_have_all(Peer.key()) :: :ok
  def handle_have_all(key),
    do: GenServer.cast(via(key), {:handle_have_all, []})

  @spec handle_have_none(Peer.key()) :: :ok
  def handle_have_none(key),
    do: GenServer.cast(via(key), {:handle_have_none, []})

  @spec handle_suggest_piece(Peer.key(), Torrent.index()) :: :ok
  def handle_suggest_piece(key, index),
    do: GenServer.cast(via(key), {:handle_suggest_piece, [index]})

  @spec handle_reject(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_reject(key, index, begin, length) do
    GenServer.cast(via(key), {:handle_reject, [index, begin, length]})
  end

  @spec handle_allowed_fast(Peer.key(), Torrent.index()) :: :ok
  def handle_allowed_fast(key, index),
    do: GenServer.cast(via(key), {:handle_allowed_fast, [index]})

  def init([hash, id, socket, reserved]) do
    [status, count, downloaded, _piece_length] =
      Torrent.get(hash, [:peer_status, :pieces_count, :downloaded, :piece_length])

    state = %State{
      hash: hash,
      id: id,
      socket: socket,
      fast_extension: FastExtension.make(reserved),
      status: status,
      pieces_count: count
    }

    State.first_message(state, downloaded)

    {:ok, state}
  end

  def terminate({:shutdown, :protocol_error}, state),
    do: Acceptor.malicious_peer(state.id)

  def terminate(_, _), do: :ok

  def handle_call(:rank, _, state), do: {:reply, State.rank(state), state}

  def handle_cast({message, _}, %State{fast_extension: nil} = state)
      when message in [
             :handle_have_all,
             :handle_have_none,
             :handle_suggest_piece,
             :handle_allowed_fast,
             :handle_reject
           ] do
    {:stop, {:shutdown, :protocol_error}, state}
  end

  def handle_cast({fun, args}, state) do
    case fun do
      :handle_suggest_piece ->
        Logger.info("suggest piece")

      _ ->
        :ok
    end

    case apply(State, fun, [state | args]) do
      {:error, reason, state} ->
        {:stop, {:shutdown, reason}, state}

      state ->
        {:noreply, state}
    end
  end
end

defmodule Peer.Controller do
  use GenServer

  require Via
  require Logger

  Via.make()

  alias Peer.Sender
  alias __MODULE__.State

  @type want_unchoke_return :: {non_neg_integer(), Peer.peer_id()} | nil

  @max_unanswered_requests 5

  @spec start_link(Peer.key()) :: GenServer.on_start()
  def start_link(key) do
    GenServer.start_link(__MODULE__, key, name: via(key))
  end

  @spec upload(Peer.key(), pos_integer()) :: :ok
  def upload(key, byte_size) do
    GenServer.cast(via(key), {:upload, byte_size})
  end

  @spec have(Peer.key(), Torrent.index()) :: :ok
  def have(key, index), do: GenServer.cast(via(key), {:have, index})

  @spec interested(Peer.key(), Torrent.index()) :: :ok
  def interested(key, index) do
    GenServer.cast(via(key), {:interested, index})
  end

  @spec cancel(Torrent.hash(), Peer.peer_id(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          :ok
  def cancel(hash, peer_id, index, begin, length) do
    GenServer.cast(via({peer_id, hash}), {:cancel, index, begin, length})
  end

  @spec seed(Peer.key()) :: :ok
  def seed(key), do: GenServer.cast(via(key), :seed)

  @spec choke(Torrent.hash(), Peer.peer_id()) :: :ok
  def choke(hash, peer_id), do: GenServer.cast(via({peer_id, hash}), :choke)

  @spec unchoke(Torrent.hash(), Peer.peer_id()) :: :ok
  def unchoke(hash, peer_id), do: GenServer.cast(via({peer_id, hash}), :unchoke)

  @spec want_unchoke(Peer.key()) :: want_unchoke_return()
  def want_unchoke(key), do: GenServer.call(via(key), :want_unchoke)

  @spec reset_rank(Peer.key()) :: :ok
  def reset_rank(key), do: GenServer.cast(via(key), :reset_rank)

  @spec request(
          Torrent.hash(),
          Peer.peer_id(),
          Torrent.index(),
          Torrent.begin(),
          Torrent.length()
        ) :: :ok
  def request(hash, peer_id, index, begin, length) do
    GenServer.cast(via({peer_id, hash}), {:request, index, begin, length})
  end

  @spec handle_choke(Peer.key()) :: :ok
  def handle_choke(key), do: GenServer.cast(via(key), :handle_choke)

  @spec handle_unchoke(Peer.key()) :: :ok
  def handle_unchoke(key), do: GenServer.cast(via(key), :handle_unchoke)

  @spec handle_interested(Peer.key()) :: :ok
  def handle_interested(key) do
    GenServer.cast(via(key), :handle_interested)
  end

  @spec handle_not_interested(Peer.key()) :: :ok
  def handle_not_interested(key) do
    GenServer.cast(via(key), :handle_not_interested)
  end

  @spec handle_have(Peer.key(), Torrent.index()) :: :ok
  def handle_have(key, piece_index) do
    GenServer.cast(via(key), {:handle_have, piece_index})
  end

  @spec handle_bitfield(Peer.key(), Torrent.bitfield()) :: :ok
  def handle_bitfield(key, bitfield) do
    GenServer.cast(via(key), {:handle_bitfield, bitfield})
  end

  @spec handle_request(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_request(key, index, begin, length) do
    GenServer.cast(via(key), {:handle_request, index, begin, length})
  end

  @spec handle_piece(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def handle_piece(key, index, begin, block) do
    GenServer.cast(via(key), {:handle_piece, index, begin, block})
  end

  @spec handle_cancel(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_cancel({peer_id, hash}, index, begin, length) do
    # Logger.info "handle cancel"
    Torrent.Uploader.cancel(hash, peer_id, index, begin, length)
  end

  @spec handle_port(Peer.key(), Acceptor.port_number()) :: :ok
  def handle_port(key, port) do
    GenServer.cast(via(key), {:handle_port, port})
  end

  def init({_, hash} = key) do
    %Torrent.Struct{peer_status: status, last_index: last_index} = Torrent.get(hash)
    Sender.bitfield(key)
    {:ok, %State{key: key, status: status, pieces_count: last_index + 1}}
  end

  def terminate(:protocol_error, %State{key: {peer_id, _}}) do
    Acceptor.BlackList.put(peer_id)
  end

  def terminate(_, _), do: :ok

  def handle_call(
        :want_unchoke,
        _,
        %State{interested_of_me: true, key: {peer_id, _}} = state
      ) do
    {:reply, {state.rank, peer_id}, state}
  end

  def handle_call(:want_unchoke, _, state), do: {:reply, nil, state}

  def handle_cast(:reset_rank, state) do
    {:noreply, %State{state | rank: 0}}
  end

  def handle_cast({:have, index}, state) do
    with <<_::bits-size(index), 0::1, _::bits>> <- state.bitfield do
      Sender.have(state.key, index)
    end

    {:noreply, state}
  end

  def handle_cast(:choke, %State{choke: false} = state) do
    Sender.choke(state.key)
    {:noreply, %State{state | choke: true}}
  end

  def handle_cast(:choke, state), do: {:noreply, state}

  def handle_cast(:unchoke, %State{choke: true} = state) do
    Sender.unchoke(state.key)
    {:noreply, %State{state | choke: false}}
  end

  def handle_cast(:unchoke, state), do: {:noreply, state}

  def handle_cast({:interested, index}, state) do
    state
    |> Map.put(:status, index)
    |> check_interested()
  end

  def handle_cast({:cancel, index, begin, length}, state) do
    Sender.cancel(state.key, index, begin, length)

    new_state = Map.update!(state, :requests, &List.delete(&1, {index, begin, length}))
    make_request(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:request, index, begin, length}, state) do
    Sender.request(state.key, index, begin, length)
    new_state = Map.update!(state, :requests, &[{index, begin, length} | &1])
    make_request(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:seed, %State{interested: true} = state) do
    Sender.interested(state.key, false)
    do_seed(state)
  end

  def handle_cast(:seed, state), do: do_seed(state)

  def handle_cast({:upload, n}, %State{status: :seed} = state) do
    {:noreply, Map.update!(state, :rank, &(&1 + n))}
  end

  def handle_cast({:upload, _}, state), do: {:noreply, state}

  def handle_cast(:handle_choke, state), do: {:noreply, Map.put(state, :choke_me, true)}

  def handle_cast(:handle_unchoke, state) do
    new_state = Map.put(state, :choke_me, false)
    make_request(new_state)
    {:noreply, new_state}
  end

  def handle_cast(:handle_interested, state) do
    # Logger.info "handle interested"
    {:noreply, Map.put(state, :interested_of_me, true)}
  end

  def handle_cast(:handle_not_interested, %State{choke: false} = state) do
    Sender.choke(state.key)
    {:noreply, %State{state | interested_of_me: false, choke: true}}
  end

  def handle_cast(:handle_not_interested, state) do
    {:noreply, %State{state | interested_of_me: false}}
  end

  def handle_cast({:handle_bitfield, _}, %State{bitfield: bitfield} = state)
      when is_binary(bitfield) do
    {:stop, :protocol_error, state}
  end

  def handle_cast({:handle_bitfield, _}, %State{status: :seed} = state) do
    {:noreply, state}
  end

  def handle_cast({:handle_bitfield, bitfield}, %State{key: {_, hash}} = state) do
    Torrent.PiecesStatistic.update(hash, bitfield, state.pieces_count)

    state
    |> Map.put(:bitfield, bitfield)
    |> check_interested()
  end

  def handle_cast({:handle_have, _}, %State{status: :seed} = state) do
    {:noreply, state}
  end

  def handle_cast({:handle_have, index}, %State{bitfield: nil} = state) do
    state.pieces_count
    |> Torrent.Bitfield.make()
    |> (&Map.put(state, :bitfield, &1)).()
    |> do_handle_have(index)
  end

  def handle_cast({:handle_have, index}, state) do
    do_handle_have(state, index)
  end

  def handle_cast(
        {:handle_request, index, begin, length},
        %State{key: {peer_id, hash}} = state
      ) do
    # Logger.info "handle request"
    with true <- state.interested_of_me,
         true <- index < state.pieces_count,
         true <- Torrent.Bitfield.check?(hash, index),
         false <- state.choke do
      Torrent.Uploader.request(hash, peer_id, index, begin, length)
      {:noreply, state}
    else
      false ->
        {:stop, :protocol_error, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_cast(
        {:handle_piece, index, begin, block},
        %State{key: {peer_id, hash}} = state
      ) do
    length = byte_size(block)
    value = {index, begin, length}

    if Enum.find_value(state.requests, &(&1 == value)) do
      Torrent.Downloads.request_response(hash, index, peer_id, begin, block)

      new_state = %State{
        state
        | requests: List.delete(state.requests, value),
          rank: state.rank + length
      }

      make_request(new_state)
      {:noreply, new_state}
    else
      {:stop, :protocol_error, state}
    end
  end

  def handle_cast({:handle_port, _port}, state) do
    # DHT
    {:noreply, state}
  end

  defp do_seed(state) do
    {:noreply, %State{state | bitfield: nil, status: :seed, interested: false}}
  end

  defp make_request(
         %State{
           interested: true,
           choke_me: false,
           status: status,
           key: {peer_id, hash}
         } = state
       )
       when is_integer(status) do
    with len when len < @max_unanswered_requests <- length(state.requests) do
      Torrent.Downloads.want_request(hash, status, peer_id)
    end

    :ok
  end

  defp make_request(_), do: :ok

  defp check_interested(%State{status: status} = state)
       when is_integer(status) do
    interested = do_has_index?(status, state)

    if interested != state.interested do
      Sender.interested(state.key, interested)
    end

    new_state = Map.put(state, :interested, interested)
    make_request(new_state)
    {:noreply, new_state}
  end

  defp check_interested(state), do: {:noreply, state}

  defp do_handle_have(state, index) do
    Torrent.PiecesStatistic.inc(elem(state.key, 1), index)

    state
    |> Map.update!(:bitfield, fn <<prefix::bits-size(index), _::1, postfix::bits>> ->
      <<prefix::bits, 1::1, postfix::bits>>
    end)
    |> check_interested()
  end

  defp do_has_index?(index, state) do
    with <<_::bits-size(index), 1::1, _::bits>> <- state.bitfield do
      true
    else
      _ ->
        false
    end
  end
end

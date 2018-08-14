defmodule Torrent.Downloads.Piece do
  use GenServer, restart: :transient

  require Via
  require Logger
  Via.make()

  alias __MODULE__.{State, Request}
  alias Torrent.{FileHandle, PiecesStatistic, Server, Swarm}

  @endgame_mode_pending_block 2
  @subpiece_length trunc(:math.pow(2, 14))
  @timeout_request 60_000
  @timeout_get_request 100_000

  @type mode :: :endgame | nil

  @spec start_link({Torrent.index(), Torrent.hash(), Torrent.length()}) :: GenServer.on_start()
  def start_link({index, hash, _} = args) do
    GenServer.start_link(__MODULE__, args, name: via({index, hash}))
  end

  @spec run?(Torrent.hash(), Torrent.index()) :: boolean()
  def run?(hash, index), do: !!GenServer.whereis(via({index, hash}))

  @spec download(Torrent.hash(), Torrent.index(), __MODULE__.mode()) :: :ok
  def download(hash, index, mode) do
    GenServer.cast(via({index, hash}), {:download, mode})
  end

  @spec want_request(Torrent.hash(), Torrent.index(), Peer.peer_id()) :: :ok
  def want_request(hash, index, peer_id) do
    GenServer.cast(via({index, hash}), {:want_request, peer_id})
  end

  @spec request_response(
          Torrent.hash(),
          Torrent.index(),
          Peer.peer_id(),
          Torrent.begin(),
          Torrent.block()
        ) :: :ok
  def request_response(hash, index, peer_id, begin, block) do
    GenServer.cast(
      via({index, hash}),
      {:request_response, peer_id, begin, block}
    )
  end

  def init({index, hash, length}) do
    {:ok, %State{index: index, hash: hash, waiting: make_subpieces([], length, 0)}}
  end

  def handle_cast(
        {:download, :endgame},
        %State{waiting: [_ | _]} = state
      ) do
    Swarm.interested(state.hash, state.index)
    {:noreply, Map.put(state, :mode, :endgame)}
  end

  def handle_cast(
        {:download, mode},
        %State{waiting: [_ | _]} = state
      ) do
    Swarm.interested(state.hash, state.index)
    {:noreply, state |> update_timer() |> Map.put(:mode, mode)}
  end

  def handle_cast({:want_request, _}, %State{waiting: []} = state) do
    {:noreply, state}
  end

  def handle_cast({:want_request, peer_id}, %State{mode: :endgame} = state) do
    state.waiting
    |> Enum.take(@endgame_mode_pending_block)
    |> Enum.reject(fn subpiece ->
      Enum.find_value(state.requests, &(&1.subpiece == subpiece and peer_id == &1.peer_id))
    end)
    |> Enum.take(1)
    |> Enum.map(fn {begin, length} = subpiece ->
      Peer.request(state.hash, peer_id, state.index, begin, length)
      %Request{subpiece: subpiece, peer_id: peer_id}
    end)
    |> (&Map.update!(state, :requests, fn list -> &1 ++ list end)).()
    |> (&{:noreply, &1}).()
  end

  def handle_cast({:want_request, peer_id}, %State{waiting: [{begin, length}]} = state) do
    Peer.request(state.hash, peer_id, state.index, begin, length)
    Server.next_piece(state.hash)

    state
    |> Map.update!(:timer, fn timer ->
      :ok = cancel_timer(timer, :timeout)
      nil
    end)
    |> monitor_request(peer_id)
  end

  def handle_cast({:want_request, peer_id}, state) do
    [{begin, length} | _] = state.waiting
    Peer.request(state.hash, peer_id, state.index, begin, length)

    state
    |> update_timer()
    |> monitor_request(peer_id)
  end

  def handle_cast({:request_response, peer_id, begin, block}, state) do
    length = byte_size(block)

    {list, requests} = Enum.split_with(state.requests, &(&1.subpiece == {begin, length}))

    unless Enum.empty?(list) do
      FileHandle.write(state.hash, state.index, begin, block)

      Enum.each(list, fn request ->
        demonitor(request.ref)
        cancel_timer(request.timer, {:timeout, request.ref})

        unless peer_id == request.peer_id do
          Peer.cancel(state.hash, peer_id, state.index, begin, length)
        end
      end)

      %State{
        state
        | requests: requests,
          waiting: List.delete(state.waiting, {begin, length})
      }
      |> is_finish()
    else
      {:noreply, state}
    end
  end

  def handle_info(:timeout, state) do
    # Logger.info("timeout piece")
    Server.next_piece(state.hash)
    PiecesStatistic.make_zero(state.hash, state.index)
    PiecesStatistic.inc(state.hash,state.index)
    {:noreply, Map.put(state, :timer, nil)}
  end

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %State{waiting: []} = state
      ) do
    PiecesStatistic.make_priority(state.hash, state.index)
    do_down(state, ref)
  end

  def handle_info({:DOWN, ref, :process, _, _}, state), do: do_down(state, ref)

  def handle_info(
        {:timeout, ref},
        %State{waiting: []} = state
      ) do
    PiecesStatistic.make_priority(state.hash, state.index)
    do_timeout(state, ref)
  end

  def handle_info({:timeout, ref}, state), do: do_timeout(state, ref)

  def handle_info(_, state), do: {:noreply, state}

  defp demonitor(nil), do: :ok

  defp demonitor(ref), do: Process.demonitor(ref)

  defp monitor_request(%State{waiting: [subpiece | tail]} = state, peer_id) do
    ref =
      state.hash
      |> Peer.whereis(peer_id)
      |> Process.monitor()

    request = %Request{
      peer_id: peer_id,
      ref: ref,
      timer: Process.send_after(self(), {:timeout, ref}, @timeout_request),
      subpiece: subpiece
    }

    state = %State{
      state
      | waiting: tail,
        requests: [request | state.requests]
    }

    {:noreply, state}
  end

  defp do_down(state, ref) do
    with {[%Request{subpiece: subpiece, timer: timer}], requests} <-
           Enum.split_with(state.requests, &(&1.ref == ref)) do
      :ok = cancel_timer(timer, {:timeout, ref})

      {:noreply, %State{state | requests: requests, waiting: [subpiece | state.waiting]}}
    else
      _ ->
        {:noreply, state}
    end
  end

  defp cancel_timer(nil, _), do: :ok

  defp cancel_timer(timer, message) do
    # cancel_timer is false => message is send
    unless Process.cancel_timer(timer) do
      receive do
        ^message -> :ok
      after
        0 -> :error
      end
    else
      :ok
    end
  end

  defp do_timeout(state, ref) do
    Process.demonitor(ref)

    {[%Request{subpiece: subpiece}], requests} = Enum.split_with(state.requests, &(&1.ref == ref))

    state = %State{state | waiting: [subpiece | state.waiting], requests: requests}
    {:noreply, state}
  end

  defp is_finish(%State{requests: [], waiting: [], hash: hash, index: index}) do
    reason =
      if FileHandle.check?(hash, index) do
        Swarm.broadcast_have(hash, index)
        Server.downloaded(hash, index)
        :normal
      else
        PiecesStatistic.make_zero(hash, index)
        PiecesStatistic.inc(hash, index)
        :wrong_subpiece
      end

    {:stop, reason, nil}
  end

  defp is_finish(state), do: {:noreply, state}

  defp make_subpieces(res, len, pos) when pos + @subpiece_length >= len do
    [{pos, len - pos} | res]
  end

  defp make_subpieces(res, len, pos) do
    [{pos, @subpiece_length} | res]
    |> make_subpieces(len, pos + @subpiece_length)
  end

  defp update_timer(state) do
    Map.update!(state, :timer, fn timer ->
      :ok = cancel_timer(timer, :timeout)
      Process.send_after(self(), :timeout, @timeout_get_request)
    end)
  end
end

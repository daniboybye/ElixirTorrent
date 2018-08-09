defmodule Torrent.Downloads.Piece do
  use GenServer, restart: :transient

  require Via
  require Logger
  Via.make()

  @doc """
  key = {index,hash} 
  """

  @subpiece_length trunc(:math.pow(2, 14))
  @timeout_request 60_000
  @timeout_get_request 100_000

  @spec start_link({Torrent.index(), Torrent.hash(), Torrent.length()}) :: GenServer.on_start()
  def start_link({index, hash, _} = args) do
    GenServer.start_link(__MODULE__, args, name: via({index, hash}))
  end

  @spec run?(Torrent.hash(), Torrent.index()) :: boolean()
  def run?(hash, index), do: !!GenServer.whereis(via({index, hash}))

  @spec download(Torrent.hash(), Torrent.index()) :: :ok
  def download(hash, index) do
    GenServer.cast(via({index, hash}), :download)
  end

  @spec get_request(Torrent.hash(), Torrent.index(), Peer.peer_id()) ::
          {Torrent.begin(), Torrent.length()} | nil
  def get_request(hash, index, peer_id) do
    if pid = GenServer.whereis(via({index, hash})) do
      GenServer.call(pid, {:get_request, peer_id})
    end
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
    {:ok, %__MODULE__.State{index: index, hash: hash, waiting: make_subpieces([], length, 0)}}
  end

  def handle_call({:get_request, _}, _, %__MODULE__.State{waiting: []} = state) do
    {:reply, nil, state}
  end

  def handle_call({:get_request, peer_id}, _, %__MODULE__.State{waiting: [_]} = state) do
    Torrent.Server.next_piece(state.hash)

    state
    |> Map.update!(:timer, fn timer ->
      :ok = cancel_timer(timer, :timeout)
      nil
    end)
    |> do_get_request(peer_id)
  end

  def handle_call({:get_request, peer_id}, _, state) do
    state
    |> update_timer()
    |> do_get_request(peer_id)
  end

  def handle_cast(
        :download,
        %__MODULE__.State{waiting: [_ | _]} = state
      ) do
    Torrent.Swarm.interested(state.hash, state.index)
    {:noreply, update_timer(state)}
  end

  def handle_cast({:request_response, peer_id, begin, block}, state) do
    length = byte_size(block)

    {list, requests} = Enum.split_with(state.requests, &(&1.subpiece == {begin, length}))

    unless Enum.empty?(list) do
      Torrent.FileHandle.write(state.hash, state.index, begin, block)

      Enum.each(list, fn request ->
        Process.demonitor(request.ref)
        cancel_timer(request.timer, {:timeout, request.ref})

        unless peer_id == request.peer_id do
          Peer.cancel(state.hash, peer_id, state.index, begin, length)
        end
      end)

      %__MODULE__.State{
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
    Logger.info("timeout piece")
    Torrent.Server.next_piece(state.hash)
    Torrent.PiecesStatistic.make_zero(state.hash, state.index)
    {:noreply, Map.put(state, :timer, nil)}
  end

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %__MODULE__.State{waiting: []} = state
      ) do
    Torrent.PiecesStatistic.make_priority(state.hash, state.index)
    do_down(state, ref)
  end

  def handle_info({:DOWN, ref, :process, _, _}, state), do: do_down(state, ref)

  def handle_info(
        {:timeout, ref},
        %__MODULE__.State{waiting: []} = state
      ) do
    Torrent.PiecesStatistic.make_priority(state.hash, state.index)
    do_timeout(state, ref)
  end

  def handle_info({:timeout, ref}, state), do: do_timeout(state, ref)

  def handle_info(_, state), do: {:noreply, state}

  defp do_get_request(%__MODULE__.State{waiting: [subpiece | tail]} = state, peer_id) do
    ref =
      state.hash
      |> Peer.whereis(peer_id)
      |> Process.monitor()

    request = %__MODULE__.Request{
      peer_id: peer_id,
      ref: ref,
      timer: Process.send_after(self(), {:timeout, ref}, @timeout_request),
      subpiece: subpiece
    }

    state = %__MODULE__.State{
      state
      | waiting: tail,
        requests: [request | state.requests]
    }

    {:reply, subpiece, state}
  end

  defp do_down(state, ref) do
    with {[%__MODULE__.Request{subpiece: subpiece, timer: timer}], requests} <-
           Enum.split_with(state.requests, &(&1.ref == ref)) do
      :ok = cancel_timer(timer, {:timeout, ref})

      {:noreply,
       %__MODULE__.State{state | requests: requests, waiting: [subpiece | state.waiting]}}
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

    {[%__MODULE__.Request{subpiece: subpiece}], requests} =
      Enum.split_with(state.requests, &(&1.ref == ref))

    state = %__MODULE__.State{state | waiting: [subpiece | state.waiting], requests: requests}
    {:noreply, state}
  end

  defp is_finish(%__MODULE__.State{requests: [], waiting: [], hash: hash, index: index}) do
    reason =
      if Torrent.FileHandle.check?(hash, index) do
        Torrent.Bitfield.add_bit(hash, index)
        Torrent.Swarm.broadcast_have(hash, index)
        Torrent.Server.downloaded(hash, index)
        :normal
      else
        Torrent.PiecesStatistic.make_zero(hash, index)
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

defmodule Torrent.Server do
  use GenServer

  require Via
  require Logger

  @next_piece_timeout 2_000
  @speed_time 10_000

  Via.make()

  @spec start_link(Torrent.Struct.t()) :: GenServer.on_start()
  def start_link(torrent) do
    GenServer.start_link(__MODULE__, torrent, name: via(torrent.hash))
  end

  @spec torrent_downloaded?(Torrent.hash()) :: boolean()
  def torrent_downloaded?(hash) do
    GenServer.call(via(hash), :torrent_downloaded?)
  end

  @spec size(Torrent.hash()) :: pos_integer()
  def size(hash), do: GenServer.call(via(hash), :size)

  @spec get(Torrent.hash()) :: Torrent.Struct.t()
  def get(hash), do: GenServer.call(via(hash), :get)

  @spec downloaded(Torrent.hash(), Torrent.index()) :: :ok
  def downloaded(hash, index) do
    GenServer.cast(via(hash), {:downloaded, index})
  end

  @spec uploaded(Torrent.hash(), non_neg_integer()) :: :ok
  def uploaded(hash, bytes_size) do
    Logger.info("upload #{bytes_size}")
    GenServer.cast(via(hash), {:uploaded, bytes_size})
  end

  @spec next_piece(Torrent.hash()) :: :ok
  def next_piece(hash), do: GenServer.cast(via(hash), :next_piece)

  def init(torrent) do
    Torrent.Swarm.new_peers(torrent.hash)
    Process.send_after(self(),{:speed, 0, 0}, @speed_time)
    Process.send_after(self(), {:next_piece, :get_random}, @next_piece_timeout)
    {:ok, torrent}
  end

  def handle_call(:torrent_download?, _, state) do
    {:reply, state.left === 0, state}
  end

  def handle_call(:size, _, state) do
    {:reply, state.downloaded + state.left, state}
  end

  def handle_call(:get, _, state), do: {:reply, state, state}

  def handle_cast({:downloaded, index}, %Torrent.Struct{downloaded: 0} = state) do
    Logger.info("downloaded first piece #{index}")
    Process.send_after(self(), :unchoke, 2_000)
    do_downloaded(index, state)
  end

  def handle_cast({:downloaded, index}, state) do
    Logger.info("downloaded piece #{index}")
    do_downloaded(index, state)
  end

  def handle_cast({:uploaded, bytes_size}, state) do
    {:noreply, Map.update!(state, :uploaded, &(&1 + bytes_size))}
  end

  def handle_cast(:next_piece, %Torrent.Struct{peer_status: index} = state)
      when is_integer(index) do
    {:noreply, do_next_piece(state, :get_rare)}
  end

  def handle_info({:next_piece, _}, %Torrent.Struct{peer_status: :seed} = state) do
    {:noreply, state}
  end

  def handle_info({:next_piece, fun}, %Torrent.Struct{peer_status: nil} = state) do
    {:noreply, do_next_piece(state, fun)}
  end

  def handle_info(:unchoke, state) do
    Torrent.Swarm.unchoke(state.hash)
    Process.send_after(self(), :reset_rank, 10_000)
    {:noreply, state}
  end

  def handle_info(:reset_rank, state) do
    Torrent.Swarm.reset_rank(state.hash)
    Process.send_after(self(), :unchoke, 10_000)
    {:noreply, state}
  end

  def handle_info({:speed,downloaded, uploaded}, state) do
    Process.send_after(self(),{:speed, state.downloaded, state.uploaded}, @speed_time)
    %{active: count_peers} = Torrent.Swarm.count(state.hash)
    Logger.info "
    #{state.struct["info"]["name"]},
    download: #{(state.downloaded - downloaded)/@speed_time}KB/s,
    upload: #{(state.uploaded - uploaded)/@speed_time}KB/s,
    peers: #{count_peers}"
    if count_peers == 0 and state.status == "empty" do
      Torrent.Swarm.new_peers(state.hash)
    end
    {:noreply, state}
  end

  defp do_downloaded(index, state) do
    new_state =
      with %Torrent.Struct{left: 0} = temp <- update_downloaded(index, state) do
        Torrent.Swarm.seed(temp.hash)
        #Torrent.Downloads.stop(temp.hash)
        #Torrent.PiecesStatistic.stop(temp.hash)
        %Torrent.Struct{temp | status: "completed", peer_status: :seed}
      end

    {:noreply, new_state}
  end

  defp do_next_piece(state, fun) do
    if index = apply(Torrent.PiecesStatistic, fun, [state.hash]) do
      Torrent.Downloads.piece(state.hash, index, index_length(index, state))
      Map.put(state, :peer_status, index)
    else
      Process.send_after(self(), {:next_piece, fun}, @next_piece_timeout)
      Map.put(state, :peer_status, nil)
    end
  end

  defp index_length(index, %Torrent.Struct{last_index: last_index} = state)
       when index == last_index do
    state.last_piece_length
  end

  defp index_length(_, state), do: state.struct["info"]["piece length"]

  defp update_downloaded(index, %Torrent.Struct{downloaded: n, left: m} = state) do
    length = index_length(index, state)
    %Torrent.Struct{state | downloaded: n + length, left: m - length}
  end
end

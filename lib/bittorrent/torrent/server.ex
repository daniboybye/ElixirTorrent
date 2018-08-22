defmodule Torrent.Server do
  use GenServer

  require Via
  require Logger

  @next_piece_timeout 3_000
  @speed_time 60_000
  @until_endgame 0

  alias Torrent.{Swarm, Struct, FileHandle, PiecesStatistic, Downloads}

  Via.make()

  @spec start_link(Torrent.Struct.t()) :: GenServer.on_start()
  def start_link(torrent) do
    GenServer.start_link(__MODULE__, torrent, name: via(torrent.hash))
  end

  @spec torrent_downloaded?(Torrent.hash()) :: boolean()
  def torrent_downloaded?(hash) do
    if pid = GenServer.whereis(via(hash)) do
      GenServer.call(pid, :torrent_downloaded?)
    end
  end

  @spec size(Torrent.hash()) :: pos_integer() | nil
  def size(hash) do
    if pid = GenServer.whereis(via(hash)) do
      GenServer.call(pid, :size)
    end
  end

  @spec get(Torrent.hash()) :: Torrent.Struct.t() | nil
  def get(hash) do
    if pid = GenServer.whereis(via(hash)) do
      GenServer.call(pid, :get, 10_000)
    end
  end

  @spec new_peers(Torrent.hash()) :: :ok
  def new_peers(hash) do
    GenServer.cast(via(hash), :new_peers)
  end

  @spec downloaded(Torrent.hash(), Torrent.index()) :: :ok
  def downloaded(hash, index) do
    GenServer.cast(via(hash), {:downloaded, index})
  end

  @spec uploaded(Torrent.hash(), non_neg_integer()) :: :ok
  def uploaded(hash, bytes_size) do
    GenServer.cast(via(hash), {:uploaded, bytes_size})
  end

  @spec next_piece(Torrent.hash()) :: :ok
  def next_piece(hash), do: GenServer.cast(via(hash), :next_piece)

  def init(torrent) do
    {:ok, opts} = Registry.meta(Registry, torrent.hash)
    
    torrent = opts
      |> Keyword.fetch!(:check)
      |> check(torrent)
    
    PeerDiscovery.request(torrent)

    Process.send_after(self(), {:speed, torrent.downloaded, torrent.uploaded}, @speed_time)

    case torrent do
      %Struct{left: 0} ->
        {:ok, %Struct{torrent | status: "completed", peer_status: :seed}}

      _ ->
        Process.send_after(self(), {:next_piece, :get_random}, 5_000)
        {:ok, %Struct{torrent | status: "empty"}}
    end
  end

  def handle_call(:torrent_download?, _, state) do
    {:reply, state.left === 0, state}
  end

  def handle_call(:size, _, state) do
    {:reply, state.downloaded + state.left, state}
  end

  def handle_call(:get, _, state), do: {:reply, state, state}

  def handle_cast({:downloaded, index}, %Struct{downloaded: 0} = state) do
    # Logger.info("downloaded first piece #{index}")
    Process.send_after(self(), :unchoke, 2_000)
    {:noreply, do_downloaded(index, state)}
  end

  def handle_cast({:downloaded, index}, state) do
    # Logger.info("downloaded piece #{index}")
    {:noreply, do_downloaded(index, state)}
  end

  def handle_cast({:uploaded, bytes_size}, state) do
    {:noreply, Map.update!(state, :uploaded, &(&1 + bytes_size))}
  end

  def handle_cast(:next_piece, %Struct{peer_status: index} = state)
      when is_integer(index) do
    {:noreply, do_next_piece(state, :get_rare)}
  end

  def handle_cast(:new_peers, %Struct{left: 0} = state) do
    {:noreply, state}
  end

  def handle_cast(:new_peers, state) do
    Swarm.new_peers(state.hash)
    {:noreply, state}
  end

  def handle_info({:next_piece, _}, %Struct{peer_status: :seed} = state) do
    {:noreply, state}
  end

  def handle_info({:next_piece, fun}, %Struct{peer_status: nil} = state) do
    {:noreply, do_next_piece(state, fun)}
  end

  def handle_info(:unchoke, state) do
    Swarm.unchoke(state.hash)
    Process.send_after(self(), :reset_rank, 10_000)
    {:noreply, state}
  end

  def handle_info(:reset_rank, state) do
    Swarm.reset_rank(state.hash)
    Process.send_after(self(), :unchoke, 10_000)
    {:noreply, state}
  end

  def handle_info({:speed, downloaded, uploaded}, state) do
    Process.send_after(self(), {:speed, state.downloaded, state.uploaded}, @speed_time)
    %{active: count_peers} = Swarm.count(state.hash)
    Logger.info("
    #{state.struct["info"]["name"]},
    download: #{(state.downloaded - downloaded) / @speed_time}KB/s,
    upload: #{(state.uploaded - uploaded) / @speed_time}KB/s,
    peers: #{count_peers}")
    {:noreply, state}
  end

  defp do_downloaded(index, state) do
    with %Struct{left: 0} = temp <- update_downloaded(index, state) do
      Swarm.seed(temp.hash)
      Logger.info("SEED #{state.struct["info"]["name"]}")
      # Downloads.stop(temp.hash)
      # PiecesStatistic.stop(temp.hash)
      %Struct{temp | status: "completed", peer_status: :seed}
    end
  end

  defp do_next_piece(state, fun) do
    if index = apply(PiecesStatistic, fun, [state.hash]) do
      Downloads.piece(state.hash, index, index_length(index, state), mode(state))
      Map.put(state, :peer_status, index)
    else
      Process.send_after(self(), {:next_piece, fun}, @next_piece_timeout)
      Map.put(state, :peer_status, nil)
    end
  end

  defp mode(%Struct{left: left, struct: %{"info" => %{"piece length" => length}}})
       when left <= @until_endgame * length do
    :endgame
  end

  defp mode(_), do: nil

  defp index_length(index, %Struct{last_index: last_index} = state)
       when index == last_index do
    state.last_piece_length
  end

  defp index_length(_, state), do: state.struct["info"]["piece length"]

  defp update_downloaded(index, %Struct{downloaded: n, left: m} = state) do
    length = index_length(index, state)
    %Struct{state | downloaded: n + length, left: m - length}
  end

  defp check(false, x), do: x

  defp check(true, torrent) do
    downloaded_indexies =
      0..torrent.last_index
      |> Enum.filter(&FileHandle.check?(torrent.hash, &1))

    Enum.each(downloaded_indexies, &PiecesStatistic.delete(torrent.hash, &1))
    Enum.reduce(downloaded_indexies, torrent, &update_downloaded/2)
  end
end

defmodule Torrent.Server do
  use GenServer
  use Via
  
  require Logger

  @next_piece_timeout 3_000
  @speed_time 60_000
  @until_endgame 0

  alias Torrent.{Swarm, FileHandle, PiecesStatistic, Downloads}

  @spec start_link(Torrent.t()) :: GenServer.on_start()
  def start_link(torrent) do
    GenServer.start_link(__MODULE__, torrent, name: via(torrent.hash))
  end

  @spec downloaded?(Torrent.hash()) :: boolean()
  def downloaded?(hash) do
    with pid when is_pid(pid) <- GenServer.whereis(via(hash)) do
      GenServer.call(pid, :torrent_downloaded?)
    end
  end

  @spec size(Torrent.hash()) :: pos_integer() | nil
  def size(hash) do
    with pid when is_pid(pid) <- GenServer.whereis(via(hash)) do
      GenServer.call(pid, :size)
    end
  end

  @spec get(Torrent.hash()) :: Torrent.t() | nil
  def get(hash) do
    with pid when is_pid(pid) <- GenServer.whereis(via(hash)) do
      GenServer.call(pid, :get, 10_000)
    end
  end

  @spec tracker_response(Torrent.hash(), list(Peer.t())) :: :ok
  def tracker_response(hash, list) do
    GenServer.cast(via(hash), {:tracker_response, list})
  end

  @spec downloaded(Torrent.hash(), Torrent.index()) :: :ok
  def downloaded(hash, index) do
    Swarm.broadcast_have(hash, index)
    GenServer.cast(via(hash), {:downloaded, index})
  end

  @spec uploaded(Torrent.hash(), non_neg_integer()) :: :ok
  def uploaded(hash, bytes_size) do
    GenServer.cast(via(hash), {:uploaded, bytes_size})
  end

  @spec next_piece(Torrent.hash()) :: :ok
  def next_piece(hash), do: GenServer.cast(via(hash), :next_piece)

  def init(torrent), do: {:ok, torrent, {:continue, :init}}

  def handle_continue(:init, temp) do
    torrent =
      Registry
      |> Registry.meta({temp.hash, :check})
      |> elem(1)
      |> check(temp)
    
    Process.send_after(self(), {:speed, torrent.downloaded, torrent.uploaded}, @speed_time)

    {:noreply, tracker_request(torrent)}
  end

  def handle_call(:torrent_download?, _, state) do
    {:reply, state.left === 0, state}
  end

  def handle_call(:size, _, state) do
    {:reply, state.downloaded + state.left, state}
  end

  def handle_call(:get, _, state), do: {:reply, state, state}

  def handle_cast({:downloaded, index}, %Torrent{downloaded: 0} = state) do
    Process.send_after(self(), :unchoke, 2_000)
    {:noreply, do_downloaded(index, state)}
  end

  def handle_cast({:downloaded, index}, state) do
    {:noreply, do_downloaded(index, state)}
  end

  def handle_cast({:uploaded, bytes_size}, state) do
    {:noreply, Map.update!(state, :uploaded, &(&1 + bytes_size))}
  end

  def handle_cast(:next_piece, %Torrent{peer_status: index} = state)
      when is_integer(index) do
    {:noreply, do_next_piece(state, :get_rare)}
  end

  @started Torrent.started
  def handle_cast({:tracker_response, _}, %Torrent{peer_status: :seed, event: @started} = state) do
    {:noreply, %Torrent{state | event: Torrent.completed()}}
  end

  def handle_cast({:tracker_response, list}, %Torrent{event: @started} = state) do
    Swarm.new_peers(state.hash, list)
    Process.send_after(self(), {:next_piece, :get_random}, 2_000)
    {:noreply, %Torrent{state | event: Torrent.empty()}}
  end

  def handle_cast({:tracker_response, list}, state) do
    Swarm.new_peers(state.hash, list)
    {:noreply, state}
  end

  def handle_info({:next_piece, _}, %Torrent{peer_status: :seed} = state) do
    {:noreply, state}
  end

  def handle_info({:next_piece, fun}, %Torrent{peer_status: nil} = state) do
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

    if count_peers < 2 and state.event == 0 do
      state
      |> PeerDiscovery.get()
      |> (&Swarm.new_peers(state.hash, &1)).()
    end

    {:noreply, state}
  end

  defp do_downloaded(index, state) do
    with %Torrent{left: 0} = temp <- update_downloaded(index, state) do
      Swarm.seed(temp.hash)
      IO.puts("downloaded #{state.struct["info"]["name"]}")
      # Downloads.stop(temp.hash)
      # PiecesStatistic.stop(temp.hash)
      %Torrent{temp | event: Torrent.completed(), peer_status: :seed}
    end
  end

  defp do_next_piece(state, fun) do
    if index = apply(PiecesStatistic, fun, [state.hash]) do
      Downloads.piece(state.hash, index, index_length(index, state), mode(state))
    else
      Process.send_after(self(), {:next_piece, fun}, @next_piece_timeout)
    end

    %Torrent{state | peer_status: index}
  end

  defp mode(%Torrent{left: left, struct: %{"info" => %{"piece length" => length}}})
       when left <= @until_endgame * length do
    :endgame
  end

  defp mode(_), do: nil

  defp index_length(index, %Torrent{last_index: last_index} = state)
       when index == last_index do
    state.last_piece_length
  end

  defp index_length(_, state), do: state.struct["info"]["piece length"]

  defp update_downloaded(index, %Torrent{downloaded: n, left: m} = state) do
    length = index_length(index, state)
    %Torrent{state | downloaded: n + length, left: m - length}
  end

  defp tracker_request(%Torrent{struct: %{"announce-list" => x}} = torrent) do
    PeerDiscovery.put(torrent.hash, x)
    torrent
  end
  
  defp tracker_request(%Torrent{struct: %{"announce" => x}} = torrent) do
    PeerDiscovery.put(torrent.hash, [[x]])
    torrent
  end

  defp tracker_request(%Torrent{struct: %{"nodes" => nodes}} = torrent) do
    Enum.map(nodes, fn [host, port] -> :ok end)
    torrent
  end

  defp check(false, x), do: x

  defp check(true, torrent) do
    downloaded_indexies =
      0..torrent.last_index
      |> Enum.filter(&FileHandle.check?(torrent.hash, &1))

    Enum.each(downloaded_indexies, &PiecesStatistic.delete(torrent.hash, &1))
    
    with %Torrent{left: 0} = temp <- Enum.reduce(downloaded_indexies, torrent, &update_downloaded/2) do
      %Torrent{temp | peer_status: :seed}
    end 
  end
end

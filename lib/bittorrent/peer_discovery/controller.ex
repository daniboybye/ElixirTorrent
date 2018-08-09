defmodule PeerDiscovery.Controller do
  use GenServer

  # 10minutes
  @timeout_refresh 600_000

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec first_request(Path.t()) ::
          {:ok, Torrent.hash()}
          | :ignore
          | {:error, {:already_started, pid()} | :max_children | term()}
          | :error_tracker_request
  def first_request(file_name) do
    GenServer.call(
      __MODULE__,
      {:first_request!, file_name},
      60_000
    )
  end

  @spec has_hash?(Torrent.hash()) :: boolean()
  def has_hash?(hash), do: GenServer.call(__MODULE__, {:has_hash?, hash})

  @spec get(Torrent.hash()) :: [Peer.peer()]
  def get(hash), do: GenServer.call(__MODULE__, {:get, hash})

  @spec delete(Torrent.hash()) :: :ok
  def delete(hash), do: GenServer.cast(__MODULE__, {:delete, hash})

  def init(_) do
    Process.send_after(self(), :refresh, @timeout_refresh)
    {:ok, %__MODULE__.State{}}
  end

  def handle_call({:has_hash?, hash}, _, state) do
    {:reply, Map.has_key?(state.peers, hash), state}
  end

  def handle_call({:get, hash}, _, state) do
    {:reply, Map.get(state.peers, hash), state}
  end

  def handle_call({:first_request!, file_name}, from, state) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(PeerDiscovery.Requests, Tracker, :first_request!, [
        file_name,
        PeerDiscovery.peer_id(),
        Acceptor.port()
      ])

    {:noreply, Map.update!(state, :requests, &Map.put(&1, ref, from))}
  end

  def handle_cast({:put, hash, peers}, state) do
    {:noreply, Map.update!(state, :peers, &Map.put(&1, hash, peers))}
  end

  def handle_cast({:delete, hash}, state) do
    {:noreply, Map.update!(state, :peers, &Map.delete(&1, hash))}
  end

  defp request(hash) do
    Task.Supervisor.start_child(PeerDiscovery.Requests, fn ->
      response =
        Tracker.request!(
          Torrent.get(hash),
          PeerDiscovery.peer_id(),
          Acceptor.port()
        )

      GenServer.cast(__MODULE__, {:put, hash, response})
    end)
  end

  def handle_info(:refresh, state) do
    state.peers
    |> Map.keys()
    |> Enum.each(&request/1)

    Process.send_after(self(), :refresh, @timeout_refresh)
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {from, requests} = Map.pop(state.requests, ref)
    GenServer.reply(from, :error_tracker_request)
    {:noreply, %__MODULE__.State{state | requests: requests}}
  end

  def handle_info({ref, {torrent, peers}}, state) do
    {from, requests} = Map.pop(state.requests, ref)

    Task.Supervisor.start_child(PeerDiscovery.Requests, fn ->
      torrent
      |> Torrents.start_torrent()
      |> case do
        res when is_tuple(res) and elem(res, 0) == :ok ->
          {:ok, torrent.hash}

        error ->
          PeerDiscovery.delete(torrent.hash)
          error
      end
      |> (&GenServer.reply(from, &1)).()
    end)

    {
      :noreply,
      %__MODULE__.State{
        state
        | requests: requests,
          peers: Map.put(state.peers, torrent.hash, peers)
      }
    }
  end
end

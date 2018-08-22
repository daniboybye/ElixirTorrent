defmodule PeerDiscovery.Controller do
  use GenServer, start: {__MODULE__, :start_link, []}

  alias __MODULE__.State

  require Logger

  @spec start_link() :: GenServer.on_start()
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec request(Torrent.Struct.t()) :: :ok
  def request(torrent) do
    GenServer.cast(__MODULE__, {:request, torrent})
  end

  @spec has_hash?(Torrent.hash()) :: boolean()
  def has_hash?(hash), do: GenServer.call(__MODULE__, {:has_hash?, hash})

  @spec get(Torrent.hash()) :: [Peer.peer()]
  def get(hash), do: GenServer.call(__MODULE__, {:get, hash})

  def init(_), do: {:ok, %State{}}

  def handle_call({:has_hash?, hash}, _, state) do
    {:reply, Map.has_key?(state.peers, hash), state}
  end

  def handle_call({:get, hash}, _, state) do
    {:reply, Map.get(state.peers, hash, []), state}
  end

  def handle_cast({:request, torrent}, state) do
    {:noreply, request(torrent, state)}
  end

  def handle_info({:request, %Torrent.Struct{} = torrent}, state) do
    {:noreply, request(torrent, state)}
  end

  def handle_info({:request, hash}, state) do
    if torrent = Torrent.get(hash) do
      {:noreply, request(torrent, state)}
    else
      {:noreply, Map.update!(state, :peers, &Map.delete(&1, hash))}
    end
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {x, requests} = Map.pop(state.requests, ref)
    Process.send_after(self(), {:request, x}, 40_000)
    {:noreply, Map.put(state, :requests, requests)}
  end

  def handle_info({ref, %{"failure reason" => reason}}, state) do
    Logger.info "request failure reason: #{reason}"
    {x, state} = pop_in(state, [:requests, ref])
    Torrent.restart(get_hash(x))
    {:noreply, state}
  end

  def handle_info({ref, %{"peers" => peers} = map}, state) do
    {x, state} = pop_in(state, [:requests, ref])
    Torrent.new_peers(get_hash(x))
    Process.send_after(self(), {:request, get_hash(x)}, Map.get(map, "interval", 900) * 1_000)

    {
      :noreply, 
      Map.update!(
        state, 
        :peers, 
        &Map.put(&1, get_hash(x), Enum.map(peers, &parse_peer/1))
      )
    }
  end

  defp parse_peer(<<ip1, ip2, ip3, ip4, port::16>>) do
    %{"ip" => Enum.join([ip1, ip2, ip3, ip4], "."), "port" => port, "peer id" => nil}
  end

  defp parse_peer(%{"ip" => _, "port" => _, "peer id" => _} = peer), do: peer

  defp request(torrent, state) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(PeerDiscovery.Requests, Tracker, :request!, [
        torrent,
        PeerDiscovery.peer_id(),
        Acceptor.port()
      ])

    Map.update!(state, :requests, &Map.put(&1, ref, torrent.hash))
  end

  defp get_hash(x), do: with %Torrent.Struct{} <- x, do: x.hash
end

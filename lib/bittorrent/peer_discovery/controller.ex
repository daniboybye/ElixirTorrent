defmodule PeerDiscovery.Controller do
  use GenServer, start: {__MODULE__, :start_link, []}

  alias __MODULE__.State

  require Logger

  @spec start_link() :: GenServer.on_start()
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec request(Torrent.hash(), list(Tracker.announce())) :: :ok
  def request(hash, list) do
    GenServer.cast(__MODULE__, {:request, hash, list})
  end

  @spec get(Torrent.hash() | Torrent.t()) :: [Peer.t()]
  def get(%Torrent{} = torrent) do
    GenServer.call(__MODULE__, {:get, torrent})
  end

  def get(hash), do: GenServer.call(__MODULE__, {:get, hash})

  def init(_), do: {:ok, %State{}}

  def handle_call({:get, %Torrent{} = torrent}, _, state) do
    torrent
    |> Torrent.get_announce_list()
    |> Enum.reduce([], &(Map.get(state.peers[&1],torrent.hash,[]) ++ &2))
    |> (&{:reply, &1, state}).()
  end

  def handle_call({:get, hash}, _, state) do
    state.peers
    |> Map.values()
    |> Enum.filter(&(elem(&1, 0) == hash))
    |> Enum.flat_map(&elem(&1, 1))
    |> (&{:reply, &1, state}).()
  end

  def handle_cast({:request, hash, list}, state) do
    list
    |> Enum.into( %{}, &{&1, %{}} )
    |> add_announce_list(state)
    |> first_request_announce_list(list,hash)
    |> (&{:noreply, &1}).()
  end

  def handle_info({:request, {announce, key}}, state) do
    {:noreply, do_request(announce, key, state)}
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, {%HTTPoison.Error{reason: :etimedout},_}},state) do
    {x, state} = pop_in(state, [Access.key!(:requests), ref])
    Process.send_after(self(), {:request, x}, 1_000*60*5)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {x, state} = pop_in(state, [Access.key!(:requests), ref])
    Process.send_after(self(), {:request, x}, Tracker.default_interval() * 1_000)
    {:noreply, state}
  end

  #UDP timeout
  def handle_info({ref, %Tracker.Error{reason: :timeout}}, state) do
    {x, state} = pop_in(state, [Access.key!(:requests), ref])
    Process.send_after(self(), {:request, x}, Tracker.default_interval() * 1_000)
    {:noreply, state}
  end

  def handle_info({ref, %Tracker.Error{reason: reason}}, state) do
    Logger.info("request failure reason: #{reason}")
    {x, state} = pop_in(state, [Access.key!(:requests), ref])
    Process.send_after(self(), {:request, x}, Tracker.default_interval() * 1_000)
    # TODO if reason in [] do Torrent.restart
    {:noreply, state}
  end

  def handle_info({ref, %Tracker.Response{} = response}, state) do
    {{announce,x}, state} = pop_in(state, [Access.key!(:requests), ref])
    Torrent.new_peers(get_hash(x), response.peers)
    Process.send_after(self(), {:request, get_hash(x)}, response.interval * 1_000)

    {
      :noreply,
      put_in(state, [Access.key!(:peers), announce, get_hash(x)], response.peers)
    }
  end

  @spec do_request(Tracker.announce(), State.key(), State.t()) :: State.t() | no_return()
  defp do_request(announce, key, state) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(PeerDiscovery.Requests, Tracker, :request!, [
        announce,
        get_torrent(key),
        PeerDiscovery.peer_id(),
        Acceptor.port(),
        Acceptor.key()
      ])

    Map.update!(state, :requests, &Map.put(&1, ref, {announce, key}))
  end

  defp get_torrent({hash, fun}) do
    hash
    |> Torrent.get()
    |> Map.put(:event, apply(Torrent, fun, []))
  end

  defp get_torrent(hash), do: Torrent.get(hash)

  @spec get_hash(State.key()) :: Torrent.hash()
  defp get_hash(x), do: with({hash, _} <- x, do: hash)

  defp add_announce_list(map, state) do
    Map.update!(state, :peers, &Map.merge(map, &1))
  end

  defp first_request_announce_list(state,list,hash) do
    Enum.reduce(list, state, &do_request(&1, {hash, :started}, &2))
  end
end

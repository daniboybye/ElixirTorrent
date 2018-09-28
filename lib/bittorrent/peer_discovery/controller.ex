defmodule PeerDiscovery.Controller do
  use GenServer, start: {__MODULE__, :start_link, []}

  alias __MODULE__.State

  require Logger

  @spec start_link() :: GenServer.on_start()
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec put(Torrent.hash(), list(list(Tracker.announce()))) :: :ok
  def put(hash, [[_|_] | _] = list) do
    GenServer.cast(__MODULE__, {:put, hash, list})
  end

  @spec get(Torrent.hash()) :: [Peer.t()]
  def get(hash), do: GenServer.call(__MODULE__, {:get, hash})

  def init(_), do: {:ok, %State{}}

  def handle_call({:get, hash}, _, state) do
    state.dictionary
    |> Map.get(hash, %{peers: []})
    |> Map.fetch!(:peers)
    |> (&{:reply, &1, state}).()
  end

  def handle_cast({:put, hash, list}, state) do
    [[announce | _] | _] = tiers = init_tiers(list)
    
    state
    |> Map.update!( 
      :dictionary, 
      &Map.put(&1, hash, %{tiers: tiers, peers: []})
    )
    |> request({announce, hash})
  end

  def handle_info({:request, hash}, state) do
    state.dictionary
    |> get_in([hash, :tiers])
    |> case do
      [[announce | _] | _] ->
        request(state, {announce, hash})
      [] ->
        {:noreply, state}
      end
  end

  def handle_info({:DOWN, _, :process, _, :normal}, state) do 
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {{announce, hash}, new_state} = pop_in(state, [Access.key!(:requests), ref])
    handle_response(nil,new_state,hash,announce)
  end

  def handle_info({ref, response}, state) do
    {{announce, hash}, new_state} = pop_in(state, [Access.key!(:requests), ref])
    handle_response(response, new_state, hash, announce)
  end

  defp request(state, {nil, hash}) do
    Process.send_after(self(), {:request, hash}, Tracker.default_interval() * 1_000)
    {:noreply, state}
  end

  defp request(state, {announce, hash} = v) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(
        PeerDiscovery.Requests, 
        fn -> 
          case Torrent.get(hash) do
            nil ->
              :delete
            torrent ->
              Tracker.request!(
                announce,
                torrent,
                Peer.id(),
                Acceptor.port(),
                Acceptor.key()
              )
          end
        end
      )
    {:noreply, Map.update!(state, :requests, &Map.put(&1, ref, v))} 
  end

  defp handle_response(:delete, state, hash, _) do
    {:noreply, Map.update!(state, :dictionary, &Map.delete(&1, hash))}
  end

  defp handle_response(%Tracker.Error{reason: "Not a tracker", retry_in: "never"}, state, hash, announce) do
    {new_announce, temp_state} = next_announce(state, hash, announce)

    temp_state 
    |> update_in(
        [Access.key!(:dictionary), hash, :tiers],
        fn tiers -> Enum.map(tiers, &List.delete(&1, announce)) end
      )
    |> request({new_announce, hash})
  end

  #def handle_info({ref, %Tracker.Error{reason: "Overloaded", retry_in: <<x::binary>>}}, state) do
  #  String.split(x, ~r"[^0-9]") 
  #end

  defp handle_response(%Tracker.Error{reason: reason}, state, hash, announce) do
    Logger.warn("request failure reason: #{reason}")
      
    {new_announce, new_state} = next_announce(state, hash, announce)
    
    request(new_state, {new_announce, hash})
  end

  defp handle_response(%Tracker.Response{} = response, state, hash, announce) do
    #!!!
    Torrent.tracker_response(hash, response.peers)
    
    Process.send_after(self(), {:request, hash}, response.interval * 1_000)

    {
      :noreply,
      update_in(
        state, 
        [Access.key!(:dictionary), hash], 
        &update_dictionary(&1,announce, response.peers)
      )
    }
  end

  defp next_announce(state, hash, announce) do
    state.dictionary
    |> Map.fetch!(:tiers)
    |> Enum.drop_while(&not Enum.member?(&1, announce))
    |> (fn [x | y] -> {tl(Enum.drop_while(x, &announce != &1)), y} end).()
    |> case do
      {[x | _], _} ->
        {x, state}
      {[], [x | _]} ->
        {x, state}
      {[],[]} ->
        new_state = update_in(
          state, 
          [Access.key!(:dictionary), hash, :tiers],
          fn x -> Enum.reject(x, &Enum.empty?/1) |> init_tiers end
        )
        {nil, new_state}
      end
  end

  defp init_tiers(list), do: Enum.map(list, &Enum.shuffle/1)

  defp update_dictionary(%{tiers: tiers}, announce, new_peers) do
    %{ 
      tiers: List.update_at(
        tiers, 
        Enum.find_index(tiers, &Enum.member?(&1, announce)), 
        &[announce | List.delete(&1, announce)] 
        ),
      peers: new_peers
    }
  end
end

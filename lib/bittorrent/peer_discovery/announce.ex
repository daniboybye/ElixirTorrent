defmodule PeerDiscovery.Announce do
  @enforce_keys [:torrent_pid, :announce, :hash]
  defstruct [:torrent_pid, :announce, :hash, request: nil, peers: []]

  use GenServer
  use Via

  import Process, only: [send_after: 3]

  # def LSD_announce() do
  # #set IP_MULTICAST_TTL > 1
  #   a = "239.192.152.143:6771"
  #   b = "[ff15::efc0:988f]:6771"
  #   cookie = :random.uniform(1_000_000_000)
  #   [
  #     "BT-SEARCH * HTTP/1.1", 
  #     "Host: #{a or b}",
  #     "Port: #{Acceptor.port()}",
  #     "Infohash: #{ihash}",
  #     "cookie: #{cookie}",
  #     "\r\n"
  #   ]
  #   |> Enum.map(& &1 <> "\r\n")
  #   |> Enum.join("")
  # end

  alias PeerDiscovery.Requests
  alias Torrent.Model
  require Logger

  # timeout solve Bento.decode!("")

  def start_link([_pid, torrent] = args) do
    GenServer.start_link(__MODULE__, args, name: via(torrent.hash))
  end

  def get(hash),
    do: GenServer.call(via(hash), :get)

  def init([pid, torrent]) do
    state = torrent.struct
    |> extract_announce
    |> Enum.map(&Enum.shuffle/1)
    |> (&%__MODULE__{torrent_pid: pid, announce: &1, hash: torrent.hash}).()
    Process.monitor(pid)
    send_after(self(), :request, 1_000)
    {:ok, state}
  end

  def handle_call(:get, _, state),
    do: {:reply, state.peers, state}

  def handle_info(:request, state) do
    case state.announce do
      [[announce | _] | _] ->
        state = %__MODULE__{state | request: announce}
        request(state)
        {:noreply, state}

      [] ->
        {:noreply, state}
    end
  end

  def handle_info({_, %Tracker.Response{} = response}, state) do
    send_after(self(), :request, response.interval * 1_000)

    {:noreply, response(state, response)}
  end

  def handle_info({:DOWN, _, :process, pid, _}, %__MODULE__{torrent_pid: p} = state)
      when pid === p,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, _, :process, _, :normal}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, _, :process, _, _}, state),
    do: next_request(state)

  def handle_info(
        {_,
         %Tracker.Error{
           reason: "Not a tracker",
           retry_in: "never"
         }},
        state
      ) do
    new_state =
      state
      |> next_request()
      |> delete(state.request)

    {:noreply, new_state}
  end

  def handle_info({_, %Tracker.Error{reason: "Overloaded", retry_in: <<str::binary>>}}, state) do
    String.split(str, ~r"[^0-9]", part: 2)
    |> hd()
    |> case do
      <<>> ->
        state

      _number ->
        # ignor timeout
        state
    end
    |> next_request
  end

  def handle_info({_, %Tracker.Error{reason: reason}}, state) do
    Logger.warn("request failure reason: #{reason}")

    {:noreply, next_request(state)}
  end

  defp request(%__MODULE__{request: nil}),
    do: send_after(self(), :request, Tracker.default_interval() * 1_000)

  defp request(%__MODULE__{request: announce, hash: hash}) do
    Task.Supervisor.async_nolink(
      Requests,
      fn ->
        Tracker.request!(
          announce,
          Torrent.get(hash),
          Peer.id(),
          Acceptor.port(),
          Acceptor.key()
        )
      end
    )
  end

  defp delete(state, announce) do
    Map.update!(
      state,
      :announce,
      fn x ->
        Enum.map(x, &List.delete(&1, announce))
        |> Enum.reject(&Enum.empty?/1)
      end
    )
  end

  defp response(state, response) do
    Model.update_event(state.hash)

    if Model.get(state.hash, :peer_status) != :seed,
      do: Acceptor.handshakes(response.peers, state.hash)

    send_after(self(), :request, response.interval * 1_000)
    
    %__MODULE__{
      state
      | announce:
          List.update_at(
            state.announce,
            Enum.find_index(state.announce, &Enum.member?(&1, state.request)),
            &[state.request | List.delete(&1, state.request)]
          ),
        peers: response.peers
    }
  end

  defp next_request(%__MODULE__{request: announce} = state) do
    state.announce
    |> Enum.drop_while(&(not Enum.member?(&1, announce)))
    |> (fn [x | y] -> {tl(Enum.drop_while(x, &(announce != &1))), y} end).()
    |> case do
      {[x | _], _} ->
        x

      {[], [x | _]} ->
        x

      {[], []} ->
        nil
    end
    |> (&%__MODULE__{state | request: &1}).()
    |> request
  end

  defp extract_announce(%{"announce-list" => x}), do: x

  defp extract_announce(%{"announce" => x}), do: [[x]]

  defp extract_announce(%{"nodes" => _nodes}) do
    # Enum.map(nodes, fn [host, port] -> :ok end)
    # TODO
    Logger.info("not implement: TORRENT without TRACKER")

    [[]]
  end
end

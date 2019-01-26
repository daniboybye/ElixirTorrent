defmodule PeerDiscovery.Announce do
  @enforce_keys [:torrent_pid, :hash]
  defstruct [:torrent_pid, :hash, requests: %{}, peers: %{}]

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

  def start_link([_pid, torrent] = args) do
    GenServer.start_link(__MODULE__, args, name: via(torrent.hash))
  end

  def get(hash),
    do: GenServer.call(via(hash), :get)

  def connecting_to_peers(hash),
    do: GenServer.cast(via(hash), :connecting_to_peers)

  def init([pid, torrent]) do
    Process.monitor(pid)

    torrent.metadata
    |> extract_announce
    |> Enum.reduce(0, fn announce, timeout ->
      send_after(self(), {:request, announce}, timeout)
      timeout + 500
    end)

    state = %__MODULE__{
      torrent_pid: pid,
      hash: torrent.hash
    }

    {:ok, state}
  end

  def handle_call(:get, _, state),
    do: {:reply, Map.values(state.peers), state}

  def handle_cast(:connecting_to_peers, state) do
    Acceptor.handshakes(Map.values(state.peers), state.hash)
    {:noreply, state}
  end

  def handle_info({:request, announce}, %__MODULE__{hash: hash} = state) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(
        Requests,
        Tracker,
        :request!,
        [announce, hash]
      )

    {:noreply, put_in(state, [Access.key!(:requests), ref], announce)}
  end

  def handle_info({ref, %Tracker.Response{} = response}, state) do
    {announce, state} = next_request(state, ref, response.interval)
    state = put_in(state, [Access.key!(:peers), announce], response.peers)

    Model.update_event(state.hash)

    if Model.get(state.hash, :peer_status) != :seed,
      do: Acceptor.handshakes(response.peers, state.hash)

    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, pid, _}, %__MODULE__{torrent_pid: p} = state)
      when pid === p,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, _, :process, _, :normal}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: failure(state, ref, Tracker.default_interval())

  def handle_info(
        {ref,
         %Tracker.Error{
           reason: "Not a tracker",
           retry_in: "never"
         }},
        state
      ) do
    {:noreply, Map.update!(state, :requests, &Map.delete(&1, ref))}
  end

  def handle_info({ref, %Tracker.Error{reason: "Overloaded", retry_in: <<str::binary>>}}, state) do
    timeout =
      case String.split(str, ~r"[^0-9]", part: 2) do
        [<<>>, _] ->
          Tracker.default_interval()

        [number, _] ->
          number
      end

    failure(state, ref, timeout)
  end

  def handle_info({ref, %Tracker.Error{reason: reason}}, state) do
    Logger.warn("request failure reason: #{reason}")

    failure(state, ref, Tracker.default_interval())
  end

  def handle_info({ref, _}, state) do
    failure(state, ref, Tracker.default_interval())
  end

  defp next_request(state, ref, timeout) do
    result = {announce, _} = pop_in(state, [Access.key!(:requests), ref])
    send_after(self(), {:request, announce}, timeout * 1_000)
    result
  end

  defp failure(state, ref, timeout) do
    {announce, state} = next_request(state, ref, timeout)
    {:noreply, Map.update!(state, :peers, &Map.delete(&1, announce))}
  end

  defp extract_announce(%{"announce-list" => x}), do: List.flatten(x)

  defp extract_announce(%{"announce" => x}), do: [x]

  defp extract_announce(%{"nodes" => _nodes}) do
    # Enum.map(nodes, fn [host, port] -> :ok end)
    # TODO
    Logger.info("not implement: TORRENT without TRACKER")

    []
  end
end

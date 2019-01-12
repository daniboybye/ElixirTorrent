defmodule Torrent.Downloads.Piece do
  use GenServer
  use Via

  require Logger

  alias __MODULE__.State
  alias Torrent.{FileHandle, PiecesStatistic}

  @type mode :: :endgame | nil
  @type callback_peer_request :: (Torrent.index(), Torrent.begin(), Torrent.length() -> any())

  @max_length trunc(:math.pow(2, 14))
  @compile {:inline, max_length: 0}

  def child_spec(args) do
    %{
      id: __MODULE__,
      restart: :transient,
      start: {__MODULE__, :start_link, args}
    }
  end

  @spec start_link(Torrent.hash(), Torrent.index()) :: GenServer.on_start()
  def start_link(hash, index) do
    GenServer.start_link(__MODULE__, {hash, index}, name: key(index, hash))
  end

  def max_length, do: @max_length

  def download(pid, downloaded, requests_are_dealt),
    do: GenServer.cast(pid, {:download, [downloaded, requests_are_dealt]})

  @spec request(Torrent.hash(), Torrent.index(), Peer.id(), callback_peer_request()) :: :ok
  def request(hash, index, peer_id, callback), 
  do: GenServer.cast(key(index, hash), {:request, [peer_id, callback]})

  @spec response(
          Torrent.hash(),
          Torrent.index(),
          Peer.id(),
          Torrent.begin(),
          Torrent.block()
        ) :: :ok
  def response(hash, index, peer_id, begin, block) do
    GenServer.cast(
      key(index, hash),
      {:response, [peer_id, begin, block]}
    )
  end

  @spec reject(Torrent.hash(), Torrent.index(), Peer.id(), Torrent.begin(), Torrent.length()) ::
          :ok
  def reject(hash, index, peer_id, begin, length) do
    GenServer.cast(
      key(index, hash),
      {:reject, [peer_id, begin, length]}
    )
  end

  def init(arg), do: {:ok, State.make(arg)}

  def handle_cast({fun, args}, state) do
    is_complete(apply(State, fun, [state | args]))
  end

  def handle_info(:timeout, state) do
    # Logger.info("timeout piece")
    state.requests_are_dealt.()
    PiecesStatistic.set(state.hash, state.index, nil)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    {:noreply, State.down(state, ref)}
  end

  def handle_info({:timeout, peer_id}, state) do
    {:noreply, State.timeout(state, peer_id)}
  end

  defp is_complete(%State{requests: [], waiting: []} = state) do
    reason =
      if FileHandle.check?(state.hash, state.index) do
        state.downloaded.()
        :normal
      else
        {:shutdown, :wrong_subpiece}
      end

    {:stop, reason, nil}
  end

  defp is_complete(state), do: {:noreply, state}

  @spec key(Torrent.index(), Torrent.hash()) :: GenServer.name()
  defp key(index, hash), do: via({index, hash})
end

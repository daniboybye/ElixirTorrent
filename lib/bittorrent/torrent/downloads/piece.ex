defmodule Torrent.Downloads.Piece do
  use GenServer, restart: :transient
  use Via

  require Logger

  alias __MODULE__.State
  alias Torrent.{FileHandle, PiecesStatistic, Server}

  @type mode :: :endgame | nil
  @type args :: [index: Torrent.index(), hash: Torrent.hash(), length: Torrent.length()]
  @type callback :: (Torrent.index(), Torrent.begin(), Torrent.length() -> any())

  @max_length trunc(:math.pow(2, 14))
  @compile {:inline, max_length: 0}

  @spec start_link(args()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(
      __MODULE__, 
      args, 
      name: key(
        Keyword.fetch!(args, :index),  
        Keyword.fetch!(args, :hash)
      )
    )
  end

  def max_length, do: @max_length

  @spec download(Torrent.hash(), Torrent.index(), mode()) :: :ok
  def download(hash, index, mode \\ nil) do
    GenServer.cast(key(index, hash), {:download, [mode]})
  end

  @spec request(Torrent.hash(), Torrent.index(), Peer.id(), callback()) :: :ok
  def request(hash, index, peer_id, callback) do
    GenServer.cast(key(index, hash), {:request, [peer_id, callback]})
  end

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

  @spec reject(Torrent.hash(), Torrent.index(), Peer.id(), Torrent.begin(), Torrent.length()) :: :ok
  def reject(hash, index, peer_id, begin, length) do
    GenServer.cast(
      key(index, hash),
      {:reject, [peer_id, begin, length]}
    )
  end

  def init(arg), do: {:ok, State.make(arg)}

  def handle_call(:get,_,state), do: {:reply, state, state}

  def handle_cast({fun, args}, state) do
    is_complete(apply(State, fun, [state | args]))
  end

  def handle_info(:timeout, state) do
    # Logger.info("timeout piece")
    Server.next_piece(state.hash)
    PiecesStatistic.make_zero(state.hash, state.index)
    PiecesStatistic.inc(state.hash, state.index)
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
        Server.downloaded(state.hash, state.index)
        :normal
      else
        PiecesStatistic.make_zero(state.hash, state.index)
        PiecesStatistic.inc(state.hash, state.index)
        :wrong_subpiece
      end

    {:stop, reason, nil}
  end

  defp is_complete(state), do: {:noreply, state}

  @spec key(Torrent.index(), Torrent.hash()) :: GenServer.name()
  defp key(index, hash), do: via({index, hash})
end

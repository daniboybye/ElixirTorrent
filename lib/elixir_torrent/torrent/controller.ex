defmodule Torrent.Controller do
  use GenServer

  import Process, only: [send_after: 3]

  alias Torrent.{Swarm, PiecesStatistic, Downloads, Model}

  @next_piece_timeout 2_500

  @spec start_link(Torrent.hash()) :: GenServer.on_start()
  def start_link(hash),
    do: GenServer.start_link(__MODULE__, hash)

  def init(hash) do
    send_after(self(), {:next_piece, :random}, 2_000)
    send_after(self(), :unchoke, 5_000)
    {:ok, hash}
  end

  def handle_info({:next_piece, strategy} = msg, hash) do
    with false <- Model.downloaded?(hash),
         count when count > 4 <- Swarm.count(hash) do
      next_piece(hash, strategy)
    else
      true ->
        Swarm.seed(hash)
        Downloads.stop(hash)

      0 ->
        Model.set_peer_status(hash, :connecting_to_peers)
        PeerDiscovery.connecting_to_peers(hash)
        send_after(self(), msg, 20_000)
    end

    {:noreply, hash}
  end

  def handle_info(:unchoke, hash) do
    send_after(self(), :reset_rank, 10_000)
    Swarm.unchoke(hash)

    {:noreply, hash}
  end

  def handle_info(:reset_rank, hash) do
    send_after(self(), :unchoke, 10_000)
    Swarm.reset_rank(hash)

    {:noreply, hash}
  end

  defp next_piece(hash, strategy) do
    if index = PiecesStatistic.choice_piece(hash, strategy) do
      pid = self()

      Downloads.piece(
        hash,
        index,
        fn -> Swarm.have(hash, index) end,
        fn -> send(pid, {:next_piece, :rare}) end
      )
    else
      send_after(self(), {:next_piece, strategy}, @next_piece_timeout)
    end

    Model.set_peer_status(hash, index)
    Swarm.interested(hash, index)
  end
end

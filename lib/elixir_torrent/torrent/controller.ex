defmodule Torrent.Controller do
  use GenServer
  use Via

  import Process, only: [send_after: 3]

  require Logger

  alias Torrent.{Swarm, PiecesStatistic, Downloads, Model}

  @next_piece_timeout 2_500
  @max_parallel_pieces 3

  @spec start_link(Torrent.hash()) :: GenServer.on_start()
  def start_link(hash),
    do: GenServer.start_link(__MODULE__, hash, name: via(hash))

  @doc """
  Nudge the download scheduler immediately (e.g. after a peer handoff or have_all).
  """
  @spec kick(Torrent.hash()) :: :ok
  def kick(hash) do
    case GenServer.whereis(via(hash)) do
      nil ->
        :ok

      pid ->
        send(pid, {:next_piece, :random})
        :ok
    end
  end

  @doc false
  @spec resume_ready(Torrent.hash()) :: :ok
  def resume_ready(hash) do
    case GenServer.whereis(via(hash)) do
      nil -> :ok
      pid -> send(pid, :resume_ready)
    end

    :ok
  end

  def init(hash) do
    {:ok, hash}
  end

  def handle_info(:resume_ready, hash) do
    Logger.info(
      "[resume] controller_start hash=#{Torrent.hex_encoded_hash(hash)} scheduling download"
    )

    send_after(self(), {:next_piece, :random}, 500)
    send_after(self(), :unchoke, 1_000)
    {:noreply, hash}
  end

  def handle_info({:next_piece, strategy} = msg, hash) do
    cond do
      Model.downloaded?(hash) ->
        mark_complete(hash)

      Swarm.count(hash) > 0 ->
        next_piece(hash, strategy)

      true ->
        [downloaded, left, status] = Model.get(hash, [:downloaded, :left, :peer_status])
        connected = Swarm.count(hash)

        Logger.info(
          "download waiting hash=#{Torrent.hex_encoded_hash(hash)} connected=#{connected} downloaded=#{downloaded} left=#{left} status=#{inspect(status)}"
        )

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
    active = Downloads.active_indices(hash)
    connected = Swarm.count(hash)

    if length(active) >= @max_parallel_pieces do
      send_after(self(), {:next_piece, strategy}, 500)
    else
      pick_and_start_piece(hash, strategy, active, connected)
    end
  end

  defp pick_and_start_piece(hash, strategy, active, connected) do
    opts = [exclude: active]
    index = PiecesStatistic.choice_piece(hash, strategy, opts)

    index =
      if index == nil do
        cleared =
          PiecesStatistic.reconcile_stale_statuses(hash, &Downloads.piece_active?(hash, &1))

        if cleared > 0 do
          Logger.info(
            "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} reconcile_stale cleared=#{cleared} active=#{length(active)}"
          )
        end

        PiecesStatistic.choice_piece(hash, strategy, opts)
      else
        index
      end

    case index do
      nil ->
        Logger.info(
          "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} strategy=#{strategy} chosen=none connected=#{connected} reason=no_available_pieces active_pieces=#{length(active)}"
        )

        if Model.downloaded?(hash) do
          mark_complete(hash)
        else
          if connected > 0, do: PeerDiscovery.connecting_to_peers(hash)
          Model.set_peer_status(hash, nil)
          send_after(self(), {:next_piece, strategy}, @next_piece_timeout)
        end

      index ->
        if Swarm.any_has_piece?(hash, index) or seeder_has_piece?(hash, index) do
          Logger.info(
            "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} strategy=#{strategy} chosen=#{index} connected=#{connected} peers_have=true active_pieces=#{length(active) + 1}"
          )

          start_piece_download(hash, index)
        else
          log_availability_mismatch(hash, index, connected)

          if connected == 0 do
            PiecesStatistic.reset_availability(hash, index)
          end

          Model.set_peer_status(hash, nil)
          PeerDiscovery.connecting_to_peers(hash)
          send_after(self(), {:next_piece, strategy}, @next_piece_timeout)
        end
    end
  end

  defp start_piece_download(hash, index) do
    pid = self()

    Downloads.piece(
      hash,
      index,
      fn -> Swarm.have(hash, index) end,
      fn -> send(pid, {:next_piece, :rare}) end
    )

    Model.set_peer_status(hash, index)
    Swarm.interested_for_piece(hash, index)
  end

  defp seeder_has_piece?(hash, index) do
    PiecesStatistic.availability(hash, index) > 0 and
      Enum.any?(Swarm.peer_supervisors(hash), &peer_offers_piece?(&1, index))
  end

  defp peer_offers_piece?(pid, index) do
    case Peer.get_key(pid) do
      key when is_tuple(key) -> safe_peer_has_piece?(key, index)
      _ -> false
    end
  end

  defp safe_peer_has_piece?(key, index) do
    Peer.Controller.has_all?(key) or Peer.Controller.has_index?(key, index)
  catch
    :exit, _ -> false
  end

  defp mark_complete(hash) do
    Model.set_peer_status(hash, :seed)
    Swarm.seed(hash)
    Downloads.stop(hash)
  end

  defp log_availability_mismatch(hash, index, connected) do
    seeder_count =
      hash
      |> Swarm.peer_supervisors()
      |> Enum.count(fn pid ->
        case Peer.get_key(pid) do
          key when is_tuple(key) -> safe_peer_has_all?(key)
          _ -> false
        end
      end)

    Logger.warning(
      "[piece_picker] hash=#{Torrent.hex_encoded_hash(hash)} chosen=#{index} connected=#{connected} peers_have=false seeders=#{seeder_count} stat=#{PiecesStatistic.availability(hash, index)}"
    )
  end

  defp safe_peer_has_all?(key) do
    Peer.Controller.has_all?(key)
  catch
    :exit, _ -> false
  end
end

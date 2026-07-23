defmodule Torrent.Model do
  use GenServer
  use Via

  alias Torrent.{Bitfield, Session}

  require Logger

  @timeout_detect_the_speed 5 * 1_000
  # Mid-download resume checkpoint (BEP-adjacent): persist bitfield + counters to
  # `.term` so a restart loads Session.apply/2 and Resume runs :verify_saved on
  # only the pieces we claim — not a blind re-download from peers. Without this,
  # only graceful stop_and_serialize/1 or 100 % completion wrote session state;
  # crash/kill lost all partial progress.
  @checkpoint_interval 30_000
  # BEP-3 endgame: request the same block from multiple peers until the last
  # bytes arrive. Enter when ≤ this many standard piece-lengths remain (bytes,
  # not a piece count — last piece may be shorter). Was 4; raised to 10 so
  # scarce-peer swarms (CGNAT, few v6 peers) start redundant requests earlier
  # while Piece.State still caps per-block redundancy at 3.
  @until_endgame 10
  @stopped Torrent.stopped()

  @spec start_link(Torrent.t()) :: GenServer.on_start()
  def start_link(torrent),
    do: GenServer.start_link(__MODULE__, torrent, name: via(torrent.hash))

  @spec has_hash?(Torrent.hash()) :: boolean()
  def has_hash?(hash),
    do: !!GenServer.whereis(via(hash))

  @spec downloaded?(Torrent.hash()) :: boolean()
  def downloaded?(hash),
    do: GenServer.call(via(hash), :downloaded?)

  @spec get(Torrent.hash(), atom() | [atom()]) :: list(any())
  def get(hash, key),
    do: GenServer.call(via(hash), {:get, key})

  @spec get(Torrent.hash()) :: Torrent.t()
  def get(hash),
    do: GenServer.call(via(hash), :get)

  @spec uploaded_subpiece(Torrent.hash(), non_neg_integer()) :: :ok
  def uploaded_subpiece(hash, bytes_size),
    do: GenServer.cast(via(hash), {:uploaded_subpiece, bytes_size})

  @spec downloaded_piece(Torrent.hash(), Torrent.index()) :: :ok
  def downloaded_piece(hash, index),
    do: GenServer.cast(via(hash), {:downloaded_piece, index})

  @spec hash_check_failure(Torrent.hash(), Torrent.index()) :: :ok
  def hash_check_failure(hash, index),
    do: GenServer.cast(via(hash), {:hash_check_failure, index})

  def update_event(hash),
    do: GenServer.cast(via(hash), :update_event)

  def piece_length(hash, index),
    do: GenServer.call(via(hash), {:piece_length, index})

  def set_peer_status(hash, status),
    do: GenServer.cast(via(hash), {:set_peer_status, status})

  @spec sync_progress(Torrent.hash()) :: :ok
  def sync_progress(hash),
    do: GenServer.cast(via(hash), :sync_progress)

  @spec sync_progress!(Torrent.hash()) :: :ok
  def sync_progress!(hash),
    do: GenServer.call(via(hash), :sync_progress)

  @spec set_event(Torrent.hash(), 0..3) :: :ok
  def set_event(hash, event),
    do: GenServer.cast(via(hash), {:set_event, event})

  def init(%Torrent{} = torrent) do
    torrent =
      if torrent.bitfield do
        torrent
      else
        bitfield =
          torrent
          |> do_pieces_count
          |> Bitfield.make()

        %{torrent | bitfield: bitfield, added_at: torrent.added_at || DateTime.utc_now()}
      end

    torrent = reconcile_progress(torrent)
    message_for_next_detection(torrent)
    schedule_checkpoint()

    {:ok, torrent}
  end

  def handle_call(:get, _, torrent),
    do: {:reply, torrent, torrent}

  def handle_call({:get, key}, _, torrent) when is_atom(key),
    do: {:reply, do_get(key, torrent), torrent}

  def handle_call({:get, keys}, _, torrent) when is_list(keys),
    do: {:reply, Enum.map(keys, &do_get(&1, torrent)), torrent}

  def handle_call({:piece_length, index}, _, torrent),
    do: {:reply, do_piece_length(index, torrent), torrent}

  def handle_call(:downloaded?, _, torrent),
    do: {:reply, torrent.left === 0, torrent}

  def handle_call(:sync_progress, _, torrent) do
    torrent = reconcile_progress(torrent)
    {:reply, :ok, torrent}
  end

  def handle_cast({:downloaded_piece, index}, torrent) do
    if Bitfield.have?(torrent.bitfield, index) do
      {:noreply, torrent}
    else
      torrent =
        torrent
        |> update_downloaded_bytes(index, 1)
        |> if_downloaded

      {:noreply, torrent}
    end
  end

  def handle_cast({:hash_check_failure, index}, %Torrent{} = torrent) do
    if Bitfield.have?(torrent.bitfield, index),
      do: {:noreply, update_downloaded_bytes(torrent, index, 0)},
      else: {:noreply, torrent}
  end

  def handle_cast({:uploaded_subpiece, bytes_size}, torrent),
    do: {:noreply, Map.update!(torrent, :uploaded, &(&1 + bytes_size))}

  def handle_cast({:set_peer_status, status}, %Torrent{} = torrent),
    do: {:noreply, %{torrent | peer_status: status}}

  def handle_cast(:sync_progress, %Torrent{} = torrent),
    do: {:noreply, reconcile_progress(torrent)}

  def handle_cast({:set_event, event}, %Torrent{} = torrent),
    do: {:noreply, %{torrent | event: event}}

  def handle_cast(:update_event, %Torrent{event: @stopped} = torrent),
    do: {:noreply, torrent}

  def handle_cast(:update_event, %Torrent{left: 0} = torrent),
    do: {:noreply, %{torrent | event: Torrent.completed()}}

  def handle_cast(:update_event, %Torrent{} = torrent),
    do: {:noreply, %{torrent | event: Torrent.empty()}}

  def handle_info({:detected_the_speed, download, upload}, %Torrent{} = torrent) do
    message_for_next_detection(torrent)

    speed = %{
      download: detected_the_speed(torrent.downloaded, download),
      upload: detected_the_speed(torrent.uploaded, upload)
    }

    {:noreply, %{torrent | speed: speed}}
  end

  def handle_info(:checkpoint, %Torrent{left: 0} = torrent) do
    schedule_checkpoint()
    {:noreply, torrent}
  end

  def handle_info(:checkpoint, %Torrent{} = torrent) do
    last = Process.get({:checkpoint_downloaded, torrent.hash}, -1)

    if torrent.downloaded > 0 and torrent.downloaded != last do
      :ok = Session.save(torrent.hash, torrent)
      Process.put({:checkpoint_downloaded, torrent.hash}, torrent.downloaded)

      Logger.info(
        "[checkpoint] hash=#{Torrent.hex_encoded_hash(torrent.hash)} downloaded=#{torrent.downloaded} left=#{torrent.left} pieces=#{Bitfield.count(torrent.bitfield, torrent.last_index + 1)}"
      )
    end

    schedule_checkpoint()
    {:noreply, torrent}
  end

  defp do_get(:bytes_size, %Torrent{downloaded: n, left: m}),
    do: n + m

  defp do_get(:pieces_count, torrent),
    do: do_pieces_count(torrent)

  defp do_get(:piece_length, torrent),
    do: do_piece_length(torrent)

  defp do_get(:mode, %Torrent{left: 0}), do: nil

  defp do_get(:mode, torrent) do
    if torrent.left <= @until_endgame * do_piece_length(torrent),
      do: :endgame
  end

  # else mode: nil

  defp do_get(:name, torrent), do: do_name(torrent)

  defp do_get(key, torrent), do: Map.get(torrent, key)

  # Kb/s
  defp detected_the_speed(current, old),
    do: (current - old) / @timeout_detect_the_speed

  defp message_for_next_detection(torrent) do
    message = {:detected_the_speed, torrent.downloaded, torrent.uploaded}
    Process.send_after(self(), message, @timeout_detect_the_speed)
  end

  defp schedule_checkpoint do
    Process.send_after(self(), :checkpoint, @checkpoint_interval)
  end

  defp do_piece_length(index, %Torrent{last_index: last_index} = torrent)
       when index === last_index,
       do: torrent.last_piece_length

  defp do_piece_length(_, torrent),
    do: do_piece_length(torrent)

  defp do_piece_length(torrent),
    do: torrent.metadata["info"]["piece length"]

  defp do_pieces_count(%Torrent{last_index: i}), do: i + 1

  defp do_name(torrent), do: torrent.metadata["info"]["name"]

  defp update_downloaded_bytes(%Torrent{} = torrent, index, x) do
    length = do_piece_length(index, torrent)
    coef = trunc(:math.pow(-1, x))

    %{
      torrent
      | downloaded: torrent.downloaded - coef * length,
        left: torrent.left + coef * length,
        bitfield: Bitfield.set(torrent.bitfield, index, x)
    }
  end

  defp if_downloaded(%Torrent{left: 0} = torrent) do
    torrent = %{torrent | event: Torrent.completed(), peer_status: :seed}

    Logger.info(
      "download complete hash=#{Torrent.hex_encoded_hash(torrent.hash)} name=#{do_name(torrent)}"
    )

    :ok = Session.save(torrent.hash, torrent)
    torrent
  end

  defp if_downloaded(torrent), do: torrent

  @doc false
  @spec reconcile_progress(Torrent.t()) :: Torrent.t()
  def reconcile_progress(%Torrent{bitfield: nil} = torrent), do: torrent

  def reconcile_progress(%Torrent{} = torrent) do
    total = total_bytes(torrent)
    downloaded = downloaded_bytes(torrent)
    left = max(total - downloaded, 0)

    torrent = %{torrent | downloaded: downloaded, left: left}

    if left == 0 and total > 0 do
      %{torrent | event: Torrent.completed(), peer_status: :seed}
    else
      torrent
    end
  end

  defp total_bytes(%Torrent{metadata: %{"info" => %{"length" => length}}}), do: length

  defp total_bytes(%Torrent{metadata: %{"info" => %{"files" => files}}}) do
    Enum.reduce(files, 0, fn %{"length" => length}, acc -> acc + length end)
  end

  defp total_bytes(%Torrent{downloaded: downloaded, left: left}), do: downloaded + left

  defp downloaded_bytes(%Torrent{} = torrent) do
    Enum.reduce(0..torrent.last_index, 0, fn index, acc ->
      if Bitfield.have?(torrent.bitfield, index) do
        acc + do_piece_length(index, torrent)
      else
        acc
      end
    end)
  end
end

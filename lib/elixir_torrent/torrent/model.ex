defmodule Torrent.Model do
  @moduledoc """
  Per-torrent runtime stats, bitfield mirror, and periodic session checkpoints.
  """

  use GenServer
  use Via

  alias Torrent.{Bitfield, Session}

  require Logger

  @timeout_detect_the_speed 5 * 1_000
  # Averaging window for the download readout, and the point past which a torrent
  # that has not completed a single piece is called stopped — see `download_rate/1`.
  @rate_window 60 * 1_000
  @rate_window_max 10 * 60 * 1_000
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
    do: not is_nil(GenServer.whereis(via(hash)))

  @spec downloaded?(Torrent.hash()) :: boolean()
  def downloaded?(hash),
    do: GenServer.call(via(hash), :downloaded?)

  @spec get(Torrent.hash(), atom()) :: any()
  @spec get(Torrent.hash(), [atom()]) :: [any()]
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

  @spec update_event(Torrent.hash(), 0..3) :: :ok
  def update_event(hash, announced_event),
    do: GenServer.cast(via(hash), {:update_event, announced_event})

  @spec piece_length(Torrent.hash(), Torrent.index()) :: Torrent.length()
  def piece_length(hash, index),
    do: GenServer.call(via(hash), {:piece_length, index})

  @spec set_peer_status(Torrent.hash(), Peer.status()) :: :ok
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

  @spec init(Torrent.t()) :: {:ok, Torrent.t()}
  def init(%Torrent{} = torrent) do
    torrent =
      if torrent.bitfield do
        torrent
      else
        bitfield =
          torrent
          |> do_pieces_count()
          |> Bitfield.make()

        %{torrent | bitfield: bitfield, added_at: torrent.added_at || DateTime.utc_now()}
      end

    torrent = reconcile_progress(torrent)
    message_for_next_detection(torrent)
    schedule_checkpoint()

    {:ok, torrent}
  end

  @spec handle_call(term(), GenServer.from(), Torrent.t()) :: {:reply, term(), Torrent.t()}
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

  @spec handle_cast(term(), Torrent.t()) :: {:noreply, Torrent.t()}
  def handle_cast({:downloaded_piece, index}, torrent) do
    if Bitfield.have?(torrent.bitfield, index) do
      {:noreply, torrent}
    else
      torrent =
        torrent
        |> update_downloaded_bytes(index, 1)
        |> if_downloaded()

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

  def handle_cast({:update_event, _announced_event}, %Torrent{event: @stopped} = torrent),
    do: {:noreply, torrent}

  def handle_cast({:update_event, event}, %Torrent{event: event} = torrent),
    do: {:noreply, %{torrent | event: Torrent.empty()}}

  def handle_cast({:update_event, _announced_event}, %Torrent{} = torrent),
    do: {:noreply, torrent}

  @spec handle_info(term(), Torrent.t()) :: {:noreply, Torrent.t()}
  def handle_info({:detected_the_speed, _download, upload}, %Torrent{} = torrent) do
    message_for_next_detection(torrent)

    speed = %{
      download: download_rate(torrent),
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

      Logger.debug(
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

  @doc false
  @spec download_rate_for_test(Torrent.t()) :: number()
  def download_rate_for_test(torrent), do: download_rate(torrent)

  # Kb/s
  defp detected_the_speed(current, old),
    do: (current - old) / @timeout_detect_the_speed

  # Download rate in the same Kb/s units, but averaged over a window long enough to
  # contain several pieces instead of differenced over the 5 s tick.
  #
  # `downloaded` advances only when a whole piece completes and verifies, so a 5 s
  # difference is quantized to piece size: at 55 KB/s with 1 MiB pieces one lands
  # every ~19 s, so three ticks in four read exactly 0. That is what reported
  # 0 B/s for torrents demonstrably progressing (#53b).
  #
  # Two narrower fixes were tried live and both failed, which is why the window is
  # the shape it is:
  #   * An EMA over the quantized samples. Any time constant short enough to track
  #     a fast torrent still collapses between a slow torrent's pieces — observed
  #     decaying to 1e-39 — and one long enough for the slow torrent is uselessly
  #     laggy for the fast one.
  #   * Timing each arrival against the previous one. A piece completing inside a
  #     single tick makes the measured interval ~5 s, which is a real burst rate
  #     (209 KB/s on a 1 MiB piece) but a bad basis for deciding the torrent has
  #     stalled, so the readout alternated between the burst and 0.
  #
  # Averaging `delta / elapsed` over a fixed @rate_window sidesteps both: the window
  # spans enough pieces that quantization averages out, and it is the same
  # measurement used by hand when auditing this node (sum of `left` deltas over
  # ≥100 s). While a window is still open the last published average is held rather
  # than a burst rate, clamped by `piece_length / elapsed` — were the torrent still
  # going that fast, the next piece would already have landed. A torrent that
  # completes nothing for @rate_window_max is called stopped; that is generous on
  # purpose, since a genuinely slow torrent can need minutes per piece.
  defp download_rate(%Torrent{} = torrent) do
    now = System.monotonic_time(:millisecond)
    key = progress_key(torrent)
    {start_at, start_downloaded} = rate_window(key, now, torrent.downloaded)
    elapsed = max(now - start_at, 1)
    delta = torrent.downloaded - start_downloaded

    case rate_verdict(torrent, delta, elapsed) do
      {:publish, rate} ->
        Process.put(key, {now, torrent.downloaded})
        rate

      :hold ->
        torrent.speed.download

      {:ceiling, ceiling} ->
        min(torrent.speed.download, ceiling)
    end
  end

  defp rate_verdict(%Torrent{left: 0}, _delta, _elapsed), do: {:publish, 0.0}

  defp rate_verdict(_torrent, delta, elapsed) when delta > 0 and elapsed >= @rate_window,
    do: {:publish, delta / elapsed}

  # Bytes have landed inside this window, so the torrent is demonstrably moving:
  # hold the last published average until the window matures. Deliberately no
  # ceiling here — progress is proof, and applying one anyway is what made the
  # readout sawtooth from a true 100 KB/s down to 11 as the window aged, since the
  # ceiling is `piece_length / elapsed` and `elapsed` grows all window long.
  defp rate_verdict(_torrent, delta, _elapsed) when delta > 0, do: :hold

  defp rate_verdict(_torrent, 0, elapsed) when elapsed >= @rate_window_max,
    do: {:publish, 0.0}

  # Nothing at all has arrived yet. Now the ceiling is meaningful: were the torrent
  # still running faster than this, the first piece of the window would have landed.
  defp rate_verdict(torrent, 0, elapsed),
    do: {:ceiling, do_piece_length(torrent) / elapsed}

  defp progress_key(%Torrent{hash: hash}), do: {:speed_rate_window, hash}

  # The first tick has to open the window, otherwise `elapsed` would be recomputed
  # from `now` every tick and could never grow.
  defp rate_window(key, now, downloaded) do
    case Process.get(key) do
      nil ->
        window = {now, downloaded}
        Process.put(key, window)
        window

      stored ->
        stored
    end
  end

  defp message_for_next_detection(torrent) do
    message = {:detected_the_speed, torrent.downloaded, torrent.uploaded}
    Process.send_after(self(), message, @timeout_detect_the_speed)
  end

  defp schedule_checkpoint do
    Process.send_after(self(), :checkpoint, @checkpoint_interval)
  end

  defp do_piece_length(index, %Torrent{piece_lengths: lengths, last_index: last_index} = torrent)
       when is_list(lengths) do
    if index === last_index, do: torrent.last_piece_length, else: Enum.at(lengths, index)
  end

  defp do_piece_length(index, %Torrent{last_index: last_index} = torrent)
       when index === last_index,
       do: torrent.last_piece_length

  defp do_piece_length(_, torrent),
    do: do_piece_length(torrent)

  defp do_piece_length(%Torrent{piece_lengths: [first | _]}), do: first

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
      # Reconciliation can run while restoring already-complete data. It must
      # not synthesize a fresh BEP 3 "completed" event; only the live transition
      # in if_downloaded/1 owns that one-shot announce.
      %{torrent | peer_status: :seed}
    else
      torrent
    end
  end

  defp total_bytes(%Torrent{kind: :v2, piece_lengths: lengths, last_index: last_index} = torrent)
       when is_list(lengths) do
    Enum.reduce(0..last_index, 0, fn index, acc -> acc + do_piece_length(index, torrent) end)
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

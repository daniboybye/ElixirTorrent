defmodule Magnet.Fetcher.Session do
  @moduledoc false

  use GenServer

  require Logger

  alias Magnet.Fetcher

  @type progress :: %{
          round: pos_integer(),
          peers_known: non_neg_integer(),
          peers_new: non_neg_integer(),
          peers_tried: non_neg_integer(),
          status: String.t()
        }

  def start_link({%Magnet{} = magnet, caller, ref}) when is_pid(caller) and is_reference(ref) do
    GenServer.start_link(__MODULE__, {magnet, caller, ref})
  end

  @impl true
  def init({%Magnet{} = magnet, caller, ref}) do
    Process.flag(:trap_exit, true)
    hash_hex = Torrent.hex_encoded_hash(magnet.hash)

    case Registry.register(Registry, {:magnet_fetch, magnet.hash}, ref) do
      {:ok, _} ->
        Process.monitor(caller)

        Logger.info(
          "[magnet_fetch] persistent_start hash=#{hash_hex} trackers=#{length(magnet.trackers)}"
        )

        stats = [
          uploaded: 0,
          downloaded: 0,
          left: Magnet.metadata_left(),
          event: Torrent.started()
        ]

        state = %{
          magnet: magnet,
          caller: caller,
          ref: ref,
          stats: stats,
          round: 0,
          known_peers: %{},
          peer_attempts: %{},
          announced_trackers: [],
          round_timer: nil,
          round_worker: nil
        }

        send(self(), :run_round)
        {:ok, state}

      {:error, {:already_registered, _}} ->
        Logger.warning("[magnet_fetch] duplicate_session hash=#{hash_hex}")
        {:stop, {:already_fetching, hash_hex}}
    end
  end

  @impl true
  def handle_info(:run_round, state) do
    round = state.round + 1
    hash_hex = Torrent.hex_encoded_hash(state.magnet.hash)

    {known_peers, peers_new, announced_trackers} =
      Fetcher.discover_and_merge_peers(state.magnet, state.stats, state.known_peers)

    announced_trackers =
      (state.announced_trackers ++ announced_trackers) |> Enum.uniq()

    peers = Fetcher.select_peers_for_round(known_peers, state.peer_attempts)

    Logger.info(
      "[magnet_fetch] round=#{round} hash=#{hash_hex} peers_known=#{map_size(known_peers)} peers_new=#{peers_new} tried=#{length(peers)}"
    )

    progress = %{
      round: round,
      peers_known: map_size(known_peers),
      peers_new: peers_new,
      peers_tried: length(peers),
      status: "fetching metadata"
    }

    notify_progress(state, progress)

    peer_attempts = Fetcher.mark_peers_attempted(state.peer_attempts, peers)

    parent = self()

    round_worker =
      spawn_monitor(fn ->
        result = Fetcher.fetch_metadata_round(state.magnet, peers, announced_trackers)
        send(parent, {:round_result, result})
      end)

    {:noreply,
     %{
       state
       | round: round,
         known_peers: known_peers,
         peer_attempts: peer_attempts,
         announced_trackers: announced_trackers,
         round_worker: round_worker
     }}
  end

  def handle_info({:round_result, result}, state) do
    state = %{state | round_worker: nil}
    round = state.round
    hash_hex = Torrent.hex_encoded_hash(state.magnet.hash)

    case result do
      {:ok, path, trackers, private?} ->
        Logger.info("[magnet_fetch] metadata_ok hash=#{hash_hex} round=#{round}")
        Fetcher.announce_stopped(state.magnet.hash, trackers)

        if not private? and DHT.enabled?() do
          :ok = DHT.announce(state.magnet.hash, Acceptor.port())
        end

        :ok = Fetcher.on_metadata_ok(state.magnet, path)
        notify_done(state, {:ok, path})
        {:stop, :normal, state}

      {:error, :info_hash_mismatch} ->
        notify_done(state, {:error, :info_hash_mismatch})
        {:stop, :normal, state}

      {:error, _reason} ->
        backoff = Fetcher.round_backoff_ms(round)

        Logger.info(
          "[magnet_fetch] round_retry hash=#{hash_hex} round=#{round} backoff_ms=#{backoff}"
        )

        timer = Process.send_after(self(), :run_round, backoff)

        {:noreply, %{state | round_timer: timer}}
    end
  end

  def handle_info({:DOWN, ref, :process, worker_pid, reason}, %{round_worker: {worker_pid, ref}} = state) do
    state = %{state | round_worker: nil}

    if reason != :normal do
      hash_hex = Torrent.hex_encoded_hash(state.magnet.hash)

      Logger.warning(
        "[magnet_fetch] round_worker_crashed hash=#{hash_hex} reason=#{inspect(reason)}"
      )

      send(self(), {:round_result, {:error, :round_worker_crashed}})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:upgrade_magnet, %Magnet{} = incoming}, state) do
    merged = Magnet.merge_trackers(state.magnet, incoming)
    before = length(state.magnet.trackers)
    after_count = length(merged.trackers)

    if after_count > before do
      hash_hex = Torrent.hex_encoded_hash(state.magnet.hash)

      Logger.info(
        "[magnet_fetch] upgrade_trackers hash=#{hash_hex} before=#{before} after=#{after_count}"
      )

      state = cancel_round_timer(%{state | magnet: merged, round_timer: nil})
      send(self(), :run_round)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cancel, state) do
    cancel_round_timer(state)
    kill_round_worker(state)

    hash_hex = Torrent.hex_encoded_hash(state.magnet.hash)
    Logger.info("[magnet_fetch] cancelled hash=#{hash_hex}")
    notify_done(state, {:error, :cancelled})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, %{caller: pid} = state) do
    hash_hex = Torrent.hex_encoded_hash(state.magnet.hash)

    Logger.info(
      "[magnet_fetch] caller_detached hash=#{hash_hex} continuing metadata fetch in background"
    )

    {:noreply, %{state | caller: nil}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_round_timer(state)
    kill_round_worker(state)
    Registry.unregister(Registry, {:magnet_fetch, state.magnet.hash})

    if state.announced_trackers != [] do
      Fetcher.announce_stopped(state.magnet.hash, state.announced_trackers)
    end

    Magnet.Bootstrap.stop(state.magnet.hash)
    :ok
  end

  @spec cancel_round_timer(map()) :: :ok
  defp cancel_round_timer(%{round_timer: timer}) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_round_timer(_state), do: :ok

  @spec kill_round_worker(map()) :: :ok
  defp kill_round_worker(%{round_worker: {pid, _ref}}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  defp kill_round_worker(_state), do: :ok

  @spec notify_progress(map(), progress()) :: :ok
  defp notify_progress(%{caller: caller, ref: ref}, progress) when is_pid(caller) do
    if Process.alive?(caller) do
      send(caller, {:magnet_fetch_progress, ref, progress})
    end

    :ok
  end

  defp notify_progress(_state, _progress), do: :ok

  @spec notify_done(map(), {:ok, Path.t()} | {:error, term()}) :: :ok
  defp notify_done(%{caller: caller, ref: ref}, result) when is_pid(caller) do
    if Process.alive?(caller) do
      send(caller, {:magnet_fetch, ref, result})
    end

    :ok
  end

  defp notify_done(_state, _result), do: :ok
end

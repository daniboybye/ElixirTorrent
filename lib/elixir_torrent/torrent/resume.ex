defmodule Torrent.Resume do
  @moduledoc false

  use GenServer

  alias Torrent.{Bitfield, Controller, FileHandle, Model}

  require Logger

  @type mode :: :full_scan | :verify_saved | :skip

  @spec child_spec({Torrent.hash(), mode()}) :: Supervisor.child_spec()
  def child_spec({hash, mode}) do
    %{
      id: {__MODULE__, hash},
      start: {__MODULE__, :start_link, [{hash, mode}]},
      restart: :temporary
    }
  end

  @spec start_link({Torrent.hash(), mode()}) :: GenServer.on_start()
  def start_link({hash, mode}) do
    GenServer.start_link(__MODULE__, {hash, mode})
  end

  @impl GenServer
  def init({hash, mode}) do
    send(self(), :verify)
    {:ok, {hash, mode}}
  end

  @impl GenServer
  def handle_info(:verify, {hash, :skip}) do
    hash_hex = Torrent.hex_encoded_hash(hash)

    Logger.info(
      "[resume] hash=#{hash_hex} mode=skip magnet_handoff downloaded=0 left=#{Model.get(hash, :left)}"
    )

    :ok = Controller.resume_ready(hash)
    {:stop, :normal, {hash, :skip}}
  end

  def handle_info(:verify, {hash, mode}) when mode in [:full_scan, :verify_saved] do
    torrent = Model.get(hash)
    indices = verify_indices(torrent, mode)
    verify_indices_concurrent(hash, indices)
    Model.sync_progress!(hash)

    verified = Enum.count(indices, fn index -> Torrent.have?(hash, index) end)
    not_ok = length(indices) - verified

    log_resume_summary(hash, mode, indices, verified, not_ok)
    maybe_persist_complete_seed(hash)
    :ok = Controller.resume_ready(hash)

    {:stop, :normal, {hash, mode}}
  end

  defp verify_indices(torrent, :verify_saved) do
    for index <- 0..torrent.last_index, Bitfield.have?(torrent.bitfield, index), do: index
  end

  defp verify_indices(torrent, :full_scan) do
    Enum.to_list(0..torrent.last_index)
  end

  # Verify on-disk pieces with bounded concurrency via transient tasks instead
  # of driving one long-lived Piece GenServer per index. FileHandle.verify/3
  # reuses the exact do_check side effects (Model/PiecesStatistic updates,
  # :resume logging) but re-hashes straight off the shared io_devices without
  # ever starting a process. SHA-1 is CPU-bound, so schedulers_online is the
  # natural cap; each task frees its piece buffer as it finishes.
  defp verify_indices_concurrent(hash, indices) do
    indices
    |> Task.async_stream(
      fn index -> FileHandle.verify(hash, index, :resume) end,
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  # All verify tasks have completed (so every downloaded_piece cast is already
  # in Model's mailbox) before sync_progress!/1 reconciles from the bitfield —
  # preserving the original ordering guarantee.
  defp log_resume_summary(hash, mode, indices, verified, not_ok) do
    hash_hex = Torrent.hex_encoded_hash(hash)
    downloaded = Model.get(hash, :downloaded)
    left = Model.get(hash, :left)
    checked = length(indices)

    # :verify_saved only hashes bitfield-marked pieces — a mismatch is corruption.
    # :full_scan walks every index; zeros on sparse prealloc are absent, not failed.
    log =
      case mode do
        :verify_saved ->
          "[resume] hash=#{hash_hex} mode=#{mode} checked=#{checked} ok=#{verified} corrupt=#{not_ok} downloaded=#{downloaded} left=#{left}"

        :full_scan ->
          "[resume] hash=#{hash_hex} mode=#{mode} checked=#{checked} ok=#{verified} absent=#{not_ok} downloaded=#{downloaded} left=#{left}"
      end

    Logger.info(log)
  end

  defp maybe_persist_complete_seed(hash) do
    if Model.downloaded?(hash) do
      Model.set_peer_status(hash, :seed)
      :ok = Torrent.Session.save(hash, Model.get(hash))
    end
  end
end

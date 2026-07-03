defmodule Torrent.Resume do
  @moduledoc false

  use GenServer

  alias Torrent.{Bitfield, FileHandle, Model, Controller}

  require Logger

  @spec child_spec({Torrent.hash(), :full_scan | :verify_saved}) :: Supervisor.child_spec()
  def child_spec({hash, mode}) do
    %{
      id: {__MODULE__, hash},
      start: {__MODULE__, :start_link, [{hash, mode}]},
      restart: :temporary
    }
  end

  @spec start_link({Torrent.hash(), :full_scan | :verify_saved}) :: GenServer.on_start()
  def start_link({hash, mode}) do
    GenServer.start_link(__MODULE__, {hash, mode})
  end

  @impl true
  def init({hash, mode}) do
    send(self(), :verify)
    {:ok, {hash, mode}}
  end

  @impl true
  def handle_info(:verify, {hash, mode}) do
    torrent = Model.get(hash)

    indices =
      case mode do
        :verify_saved ->
          for index <- 0..torrent.last_index, Bitfield.have?(torrent.bitfield, index), do: index

        :full_scan ->
          Enum.to_list(0..torrent.last_index)
      end

    Enum.each(indices, fn index ->
      FileHandle.check?(hash, index)
    end)

    Model.sync_progress!(hash)

    verified =
      Enum.count(indices, fn index -> Torrent.have?(hash, index) end)

    failed = length(indices) - verified

    Logger.info(
      "[resume] hash=#{Torrent.hex_encoded_hash(hash)} mode=#{mode} checked=#{length(indices)} ok=#{verified} failed=#{failed} downloaded=#{Model.get(hash, :downloaded)} left=#{Model.get(hash, :left)}"
    )

    if Model.downloaded?(hash) do
      Model.set_peer_status(hash, :seed)
      Model.set_event(hash, Torrent.completed())
      :ok = Torrent.Session.save(hash, Model.get(hash))
    end

    :ok = Controller.resume_ready(hash)

    {:stop, :normal, {hash, mode}}
  end
end

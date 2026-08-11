defmodule PeerDiscovery.StartedAnnounces do
  @moduledoc """
  In-memory record of which info hashes already delivered a BEP 3 `event=started`
  announce during the **current** BEAM lifetime.

  BEP 3 § Tracker HTTP protocol defines `started` as the event sent with "the
  first request that the client makes to the tracker". Trackers use it to open a
  session row for the peer; later event-less announces refresh that row and
  `stopped` closes it. Private trackers in particular key their per-session
  accounting off `started`, so it is not a once-ever-per-torrent flag — real
  clients (libtorrent, qBittorrent, Transmission) send it on the first announce
  of every *process* lifetime.

  Two very different situations both reach `Torrent.Session.apply/2` (through
  `Torrent.init/1` → `resume_mode_for/3`, which runs on every add of a hash whose
  `.term` state file still exists) and used to be indistinguishable there:

    * **Re-added inside a live BEAM** — pause/`stop_and_serialize` then add again,
      or a plain re-add. `started` already reached a tracker this session, so the
      first announce after the resume must be event-less; resending `started`
      would make the tracker open a second session for a peer it already has.

    * **Restored after the app actually restarted** — the tracker saw our
      `stopped` (or timed the peer out). This is a brand-new session, so the
      first announce for that hash owes a `started`.

  This table draws exactly that line, and does so by construction rather than by
  bookkeeping: it is **never persisted**. A fresh BEAM starts with an empty
  table, so the first announce for any hash after a real restart re-arms
  `started`; it survives every per-torrent process, so in-process re-adds stay
  event-less.

  Entries are written only once a tracker has *accepted* an announce that carried
  `started` (`Announce.apply_tracker_response/5`), never when one is merely
  built. Many public trackers in the wild are dead (NXDOMAIN/timeout), and an
  announce that reached nobody must not count as `started` delivered — we still
  owe it to whichever tracker eventually answers.

  Backed by a public `:set` ETS table owned by a tiny GenServer so the table
  outlives the per-torrent writers and readers, mirroring
  `PeerDiscovery.SeedPeers`.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Record that a tracker accepted an `event=started` announce for `hash`.

  Idempotent: the table only ever answers "yes, this BEAM already sent it".
  """
  @spec put(Torrent.hash()) :: :ok
  def put(hash) when is_binary(hash) do
    ensure_table()
    :ets.insert(@table, {hash, true})
    :ok
  end

  @doc """
  Has a `started` announce for `hash` already been delivered this BEAM lifetime?
  """
  @spec sent?(Torrent.hash()) :: boolean()
  def sent?(hash) when is_binary(hash) do
    ensure_table()
    :ets.member(@table, hash)
  end

  @doc """
  Forget `hash`, so its next announce carries `started` again.

  Called when the persisted session is dropped (`Torrent.Session.delete/1`):
  removing a torrent ends its tracker session, and re-adding it later is a new
  one. Also keeps the table from retaining hashes the client no longer knows.
  """
  @spec delete(Torrent.hash()) :: :ok
  def delete(hash) when is_binary(hash) do
    ensure_table()
    :ets.delete(@table, hash)
    :ok
  end

  # Readers can run before this GenServer in test setups that skip the
  # PeerDiscovery supervisor tree; make the table lazily there.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end

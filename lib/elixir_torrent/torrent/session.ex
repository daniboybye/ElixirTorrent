defmodule Torrent.Session do
  @moduledoc false

  @spec dir() :: Path.t()
  def dir do
    Path.join([File.cwd!(), ".elixir_torrent", "state"])
  end

  @spec path(Torrent.hash()) :: Path.t()
  def path(hash) do
    Path.join(dir(), Torrent.hex_encoded_hash(hash) <> ".term")
  end

  @spec save(Torrent.hash(), Torrent.t()) :: :ok
  def save(hash, %Torrent{} = torrent) do
    File.mkdir_p!(dir())

    payload = %{
      bitfield: torrent.bitfield,
      downloaded: torrent.downloaded,
      left: torrent.left,
      uploaded: torrent.uploaded,
      added_at: torrent.added_at,
      peer_status: torrent.peer_status
    }

    hash
    |> path()
    |> then(&File.write!(&1, :erlang.term_to_binary(payload)))
  end

  @spec load(Torrent.hash()) :: {:ok, map()} | :error
  def load(hash) do
    hash
    |> path()
    |> then(fn file ->
      if File.regular?(file) do
        file
        |> File.read!()
        |> :erlang.binary_to_term()
        |> then(&{:ok, &1})
      else
        :error
      end
    end)
  rescue
    _ -> :error
  end

  @spec delete(Torrent.hash()) :: :ok
  def delete(hash) do
    # Dropping the persisted session also drops the in-memory `started` record:
    # removing a torrent ends its tracker session (BEP 3), so a later re-add is a
    # new one and owes `started` again even within the same BEAM.
    PeerDiscovery.StartedAnnounces.delete(hash)

    case path(hash) do
      file when is_binary(file) ->
        case File.rm(file) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec apply(Torrent.t(), map()) :: Torrent.t()
  def apply(%Torrent{} = torrent, session) when is_map(session) do
    %{
      torrent
      | bitfield: Map.get(session, :bitfield) || torrent.bitfield,
        downloaded: Map.get(session, :downloaded, torrent.downloaded),
        left: Map.get(session, :left, torrent.left),
        uploaded: Map.get(session, :uploaded, torrent.uploaded),
        added_at: Map.get(session, :added_at, torrent.added_at),
        peer_status: Map.get(session, :peer_status, torrent.peer_status),
        event: resume_event(torrent)
    }
  end

  # BEP 3 § Tracker HTTP protocol reserves `started` for the first announce a
  # client makes to the tracker — first announce *of a session*, not once ever per
  # info hash. `apply/2` runs from `Torrent.init/1` → `resume_mode_for/3`, which
  # fires on every add of a hash that still has a `.term` file on disk, and that
  # covers two cases needing opposite answers:
  #
  #   * Re-added inside a live BEAM (pause/`stop_and_serialize` then add again, or
  #     a plain re-add): `started` already reached a tracker this process
  #     lifetime, so announce event-less and let the tracker keep the session row
  #     it already holds for us.
  #
  #   * Restored after the app actually restarted: from the tracker's point of
  #     view the old session ended (it saw our `stopped`, or timed the peer out),
  #     so the first announce owes a fresh `started`. libtorrent, qBittorrent and
  #     Transmission all behave this way, and private trackers key their
  #     per-session accounting off that event.
  #
  # `PeerDiscovery.StartedAnnounces` is memory-only and never serialized, so it is
  # empty after a real restart and populated after an in-process one — which is
  # exactly the distinction, without persisting any extra state.
  @spec resume_event(Torrent.t()) :: 0..3
  defp resume_event(%Torrent{hash: hash} = torrent) do
    if PeerDiscovery.StartedAnnounces.sent?(hash) do
      Torrent.empty()
    else
      # Keeps whatever the caller staged (the struct default is `started`) rather
      # than hardcoding the event here.
      torrent.event
    end
  end
end

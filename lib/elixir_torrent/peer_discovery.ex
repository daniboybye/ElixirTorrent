defmodule PeerDiscovery do
  @moduledoc """
  Top-level peer discovery supervisor: tracker announces, DHT, LSD, and seed peers.
  """

  alias __MODULE__.{
    Announce,
    AnnouncesSupervisor,
    ConnectionIds,
    LSD,
    SeedPeers,
    StartedAnnounces
  }

  require Logger

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_) do
    children = [
      {
        Task.Supervisor,
        name: __MODULE__.Requests, strategy: :one_for_one, max_restarts: 3
      },
      {
        DynamicSupervisor,
        name: __MODULE__.AnnouncesSupervisor, strategy: :one_for_one, max_restarts: 3
      },
      ConnectionIds,
      SeedPeers,
      # BEP 3 § Tracker HTTP protocol — owns the memory-only table of hashes that
      # already sent `started` this BEAM lifetime, so a resume knows whether the
      # tracker still has a session open for us.
      StartedAnnounces,
      LSD
    ]

    opts = [strategy: :one_for_one]

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, opts]}
    }
  end

  @spec register(pid(), Torrent.t()) :: DynamicSupervisor.on_start_child()
  def register(pid, torrent) do
    DynamicSupervisor.start_child(
      AnnouncesSupervisor,
      {Announce, [pid, torrent]}
    )
  end

  @doc """
  (Re)start the per-torrent announce process when it is missing.

  Torrent supervisors can outlive a crashed `Announce` worker; without this,
  `connecting_to_peers/1` casts are dropped and downloads stall at connected=0.
  """
  @spec ensure_announce(Torrent.hash()) :: :ok
  def ensure_announce(hash) do
    case GenServer.whereis(Announce.name(hash)) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        with {:ok, torrent_pid} <- Torrents.supervisor_pid(hash),
             %Torrent{} = torrent <- Torrent.Model.get(hash),
             {:ok, _} <- register(torrent_pid, torrent) do
          Logger.info(
            "[peer_discovery] announce_restarted hash=#{Torrent.hex_encoded_hash(hash)}"
          )

          :ok
        else
          {:error, {:already_started, _}} ->
            :ok

          {:error, :not_found} ->
            Logger.warning(
              "[peer_discovery] announce_missing hash=#{Torrent.hex_encoded_hash(hash)} reason=no_torrent"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "[peer_discovery] announce_restart_failed hash=#{Torrent.hex_encoded_hash(hash)} reason=#{inspect(reason)}"
            )

            :ok
        end
    end
  end

  defdelegate get(hash), to: Announce

  defdelegate connecting_to_peers(hash), to: Announce

  defdelegate request_peer_refresh(hash), to: Announce

  defdelegate replenish_candidates(hash), to: Announce

  defdelegate stopped_announce(hash), to: Announce

  defdelegate connection_id(socket, ip, port), to: ConnectionIds, as: :get

  defdelegate invalidate_connection_id(socket, ip, port), to: ConnectionIds, as: :invalidate
end

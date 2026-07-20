defmodule Peer.Holepunch do
  @moduledoc """
  BEP 55 outbound hole-punch coordination — rendezvous via connected relays on dial failure.
  """

  require Logger

  alias Peer.LTEP.Session
  alias Peer.UtHolepunch

  @table :elixir_torrent_holepunch_pending
  @dedup_seconds 30
  @max_attempts 4

  @doc """
  After a direct TCP+uTP dial failure, ask a connected peer to rendezvous with
  `target` (BEP 55). Works for IPv4 and IPv6 targets.

  Skips initiating when our own NAT does endpoint-dependent (symmetric) mapping:
  the address a relay observes for us then differs from the port a punched peer
  must dial, so the punch can't complete and initiating only wastes effort. We
  still act as a relay for others regardless of our own NAT type.
  """
  @spec maybe_request(Torrent.hash(), Peer.t(), term()) :: :ok
  def maybe_request(hash, %Peer{ip: ip, port: port}, _reason) do
    if punchable_self?() and connectable_target?(ip, port) and should_attempt?(hash, ip, port) do
      case pick_relay(hash, ip, port) do
        nil ->
          :ok

        relay_key ->
          send_rendezvous(hash, relay_key, ip, port)
      end
    else
      :ok
    end
  end

  def maybe_request(_hash, _peer, _reason), do: :ok

  # Our NAT must not be symmetric to be a punch endpoint. :unknown (detection
  # not finished / unavailable) errs toward trying — a wasted punch is cheap.
  @spec punchable_self?() :: boolean()
  defp punchable_self? do
    NAT.Stun.mapping() != :endpoint_dependent
  end

  @doc false
  @spec initiate_connect(Torrent.hash(), {:inet.ip_address(), :inet.port_number()}) :: :ok
  def initiate_connect(hash, {ip, port}) do
    if should_attempt?(hash, ip, port) do
      mark_attempted(hash, ip, port)

      peer = %Peer{ip: ip, port: port}

      Task.start(fn ->
        case Acceptor.Connection.Handshakes.dial_utp_and_handshake(peer, hash) do
          :ok ->
            Logger.info(
              "[holepunch] punch_ok hash=#{Torrent.hex_encoded_hash(hash)} endpoint=#{inspect({ip, port})}"
            )

          {:error, reason} ->
            # Diagnosis done: coordinated punches that fail are overwhelmingly
            # :timeout (the simultaneous-open SYNs miss each other) — inherent to
            # hole punching, not a client defect. Back to :debug; punch_ok stays :info.
            Logger.debug(
              "[holepunch] punch_fail hash=#{Torrent.hex_encoded_hash(hash)} endpoint=#{inspect({ip, port})} reason=#{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  end

  @doc false
  @spec clear_pending(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: :ok
  def clear_pending(hash, ip, port) do
    ensure_table()
    :ets.delete(@table, dedup_key(hash, ip, port))
    :ok
  end

  @spec send_rendezvous(Torrent.hash(), Peer.key(), :inet.ip_address(), :inet.port_number()) ::
          :ok
  defp send_rendezvous(hash, relay_key, target_ip, target_port) do
    with {:ok, ltep} <- Peer.Controller.ltep_session(relay_key),
         true <- Session.peer_supports?(ltep, UtHolepunch.extension_name()),
         payload when is_binary(payload) <- encode_rendezvous(target_ip, target_port),
         id when is_integer(id) and id > 0 <-
           Session.peer_extension_id(ltep, UtHolepunch.extension_name()) do
      mark_attempted(hash, target_ip, target_port)

      case Peer.LTEP.send_extended(relay_key, id, payload) do
        :ok ->
          # High-volume, low-yield outbound attempt: under CGNAT most targets
          # are unreachable and most relays can't reach them either. The
          # interesting events (connect_recv, punch_ok) stay at :info.
          Logger.debug(
            "[holepunch] rendezvous_sent hash=#{Torrent.hex_encoded_hash(hash)} target=#{inspect({target_ip, target_port})} relay=#{Peer.log_key(relay_key)}"
          )

        {:error, reason} ->
          # Relay disconnected between pick and send — not our caller's problem.
          Logger.debug(
            "[holepunch] rendezvous_send_failed target=#{inspect({target_ip, target_port})} reason=#{inspect(reason)}"
          )
      end
    else
      _ -> :ok
    end

    :ok
  end

  @spec pick_relay(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: Peer.key() | nil
  defp pick_relay(hash, target_ip, target_port) do
    target_pid = Peer.Endpoints.get_pid(hash, target_ip, target_port)

    hash
    |> Torrent.Swarm.peer_supervisors()
    |> Enum.reject(&(target_pid != nil and &1 == target_pid))
    |> Enum.find_value(fn pid ->
      case Peer.get_key(pid) do
        key when is_tuple(key) ->
          case Peer.Controller.ltep_session(key) do
            {:ok, ltep} ->
              if Session.peer_supports?(ltep, UtHolepunch.extension_name()), do: key

            _ ->
              nil
          end

        _ ->
          nil
      end
    end)
  end

  # Punching is only worth trying right after a target is discovered: repeated
  # failures mean the pair of NATs won't cooperate, so back off exponentially
  # (30s, 2m, 8m) and give up for the session after @max_attempts.
  @spec should_attempt?(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: boolean()
  defp should_attempt?(hash, ip, port) do
    ensure_table()
    key = dedup_key(hash, ip, port)
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, ts, count}] -> count < @max_attempts and now - ts >= cooldown_seconds(count)
      _ -> true
    end
  end

  @spec cooldown_seconds(pos_integer()) :: pos_integer()
  defp cooldown_seconds(count), do: @dedup_seconds * Integer.pow(4, max(count - 1, 0))

  @spec mark_attempted(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: :ok
  defp mark_attempted(hash, ip, port) do
    ensure_table()
    key = dedup_key(hash, ip, port)

    count =
      case :ets.lookup(@table, key) do
        [{^key, _ts, c}] -> c + 1
        _ -> 1
      end

    :ets.insert(@table, {key, System.monotonic_time(:second), count})
    :ok
  end

  @spec dedup_key(Torrent.hash(), :inet.ip_address(), :inet.port_number()) ::
          {Torrent.hash(), :inet.ip_address(), :inet.port_number()}
  defp dedup_key(hash, ip, port), do: {hash, ip, port}

  @spec ensure_table() :: :ok
  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table])
        :ok

      _ ->
        :ok
    end
  end

  @spec connectable_target?(:inet.ip_address(), :inet.port_number()) :: boolean()
  defp connectable_target?(ip, port) do
    peer = %Peer{ip: ip, port: port}
    Acceptor.Connection.Handshakes.connectable_peer?(peer)
  end

  @spec encode_rendezvous(:inet.ip_address(), :inet.port_number()) :: binary() | nil
  defp encode_rendezvous(ip, port) do
    case UtHolepunch.encode(:rendezvous, ip, port) do
      bin when is_binary(bin) -> bin
      _ -> nil
    end
  end
end

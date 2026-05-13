defmodule Peer.Holepunch do
  @moduledoc """
  BEP 55 outbound hole-punch coordination — rendezvous via connected relays on dial failure.
  """

  alias Acceptor.Connection.Handshakes
  alias Peer.LTEP.Session
  alias Peer.UtHolepunch

  require Logger

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
  @spec initiate_connect(Torrent.hash(), {:inet.ip_address(), :inet.port_number()}) ::
          {:ok, pid()} | {:error, term()}
  def initiate_connect(hash, {ip, port}) do
    peer = %Peer{ip: ip, port: port}

    # A connect is the successful response to an already-counted outbound
    # rendezvous (or an inbound request relayed for another peer). Re-applying
    # the rendezvous cooldown here would suppress the simultaneous uTP open.
    Task.start(fn ->
      case Handshakes.dial_utp_and_handshake(peer, hash) do
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

  @doc false
  @spec clear_pending(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: :ok
  def clear_pending(hash, ip, port) do
    ensure_table()
    :ets.delete(@table, dedup_key(hash, ip, port))
    :ok
  end

  @doc false
  @spec attempt_info(Torrent.hash(), :inet.ip_address(), :inet.port_number()) ::
          %{
            count: pos_integer(),
            cooldown_seconds: pos_integer(),
            retry_in_seconds: non_neg_integer()
          }
          | nil
  def attempt_info(hash, ip, port) do
    ensure_table()
    key = dedup_key(hash, ip, port)
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, ts, count}] ->
        cooldown = cooldown_seconds(count)

        %{
          count: count,
          cooldown_seconds: cooldown,
          retry_in_seconds: max(cooldown - (now - ts), 0)
        }

      _ ->
        nil
    end
  end

  @spec send_rendezvous(Torrent.hash(), Peer.key(), :inet.ip_address(), :inet.port_number()) ::
          :ok
  defp send_rendezvous(hash, relay_key, target_ip, target_port) do
    with {:ok, ltep} <- Peer.Controller.ltep_session(relay_key),
         true <- Session.peer_supports?(ltep, UtHolepunch.extension_name()),
         payload when is_binary(payload) <- encode_rendezvous(target_ip, target_port),
         id when is_integer(id) and id > 0 <-
           Session.peer_extension_id(ltep, UtHolepunch.extension_name()),
         true <- reserve_attempt(hash, target_ip, target_port) do
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

    candidates =
      hash
      |> Torrent.Swarm.peer_supervisors()
      |> Enum.reject(&(target_pid != nil and &1 == target_pid))
      |> Enum.flat_map(fn pid ->
        with key when is_tuple(key) <- Peer.get_key(pid),
             {:ok, ltep, pex_endpoints} <- Peer.Controller.holepunch_relay_info(key),
             true <- Session.peer_supports?(ltep, UtHolepunch.extension_name()) do
          [{key, MapSet.member?(pex_endpoints, {target_ip, target_port})}]
        else
          _ -> []
        end
      end)

    case Enum.find(candidates, fn {_key, knows_target?} -> knows_target? end) ||
           List.first(candidates) do
      {key, _knows_target?} -> key
      nil -> nil
    end
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

  @spec reserve_attempt(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: boolean()
  defp reserve_attempt(hash, ip, port) do
    ensure_table()
    key = dedup_key(hash, ip, port)
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [] ->
        if :ets.insert_new(@table, {key, now, 1}) do
          true
        else
          reserve_attempt(hash, ip, port)
        end

      [{^key, ts, count}] ->
        cond do
          count >= @max_attempts ->
            false

          now - ts < cooldown_seconds(count) ->
            false

          replace_attempt(key, ts, count, now) ->
            true

          true ->
            reserve_attempt(hash, ip, port)
        end
    end
  end

  @spec replace_attempt(term(), integer(), pos_integer(), integer()) :: boolean()
  defp replace_attempt(key, old_timestamp, old_count, new_timestamp) do
    match_spec = [
      {
        {:"$1", old_timestamp, old_count},
        [{:"=:=", :"$1", {:const, key}}],
        [{{:"$1", new_timestamp, old_count + 1}}]
      }
    ]

    :ets.select_replace(@table, match_spec) == 1
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
    Handshakes.connectable_peer?(peer)
  end

  @spec encode_rendezvous(:inet.ip_address(), :inet.port_number()) :: binary() | nil
  defp encode_rendezvous(ip, port) do
    case UtHolepunch.encode(:rendezvous, ip, port) do
      bin when is_binary(bin) -> bin
      _ -> nil
    end
  end
end

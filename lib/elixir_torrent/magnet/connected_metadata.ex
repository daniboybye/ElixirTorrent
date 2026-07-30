defmodule Magnet.ConnectedMetadata do
  @moduledoc false

  require Logger

  # Under CGNAT, finding a metadata-holding seeder is a sampling problem: probe more
  # swarm peers in parallel and retry sooner when dials succeed but peers lack metadata.
  @max_peers 16
  @metadata_parallel 8
  @min_peers_for_round 4
  @min_peers_gather_ms 12_000
  @peer_timeout_ms 240_000
  # BEP 10 extended handshake can arrive after the base handshake; poll before skipping.
  @ltep_metadata_wait_ms 15_000

  # Peer dials from tracker lists often take 30–45s before the first TCP session
  # completes; extend the wait when the swarm gains peers so LTEP/have_all can settle.
  @wait_for_peers_ms 60_000
  @wait_extend_on_connect_ms 20_000
  @wait_max_ms 120_000
  @wait_poll_ms 200

  defp connected_cfg(key, default) do
    Application.get_env(:elixir_torrent, :magnet_connected_metadata, [])
    |> Keyword.get(key, default)
  end

  defp max_peers, do: connected_cfg(:max_peers, @max_peers)
  defp metadata_parallel, do: connected_cfg(:metadata_parallel, @metadata_parallel)
  defp min_peers_for_round, do: connected_cfg(:min_peers_for_round, @min_peers_for_round)
  defp min_peers_gather_ms, do: connected_cfg(:min_peers_gather_ms, @min_peers_gather_ms)
  defp peer_timeout_ms, do: connected_cfg(:peer_timeout_ms, @peer_timeout_ms)
  defp ltep_metadata_wait_ms, do: connected_cfg(:ltep_metadata_wait_ms, @ltep_metadata_wait_ms)
  defp wait_for_peers_ms, do: connected_cfg(:wait_for_peers_ms, @wait_for_peers_ms)

  defp wait_extend_on_connect_ms,
    do: connected_cfg(:wait_extend_on_connect_ms, @wait_extend_on_connect_ms)

  defp wait_max_ms, do: connected_cfg(:wait_max_ms, @wait_max_ms)
  defp wait_poll_ms, do: connected_cfg(:wait_poll_ms, @wait_poll_ms)

  @spec fetch(Magnet.t(), [String.t()]) ::
          {:ok, Path.t(), [String.t()], boolean()} | {:error, term()}
  def fetch(%Magnet{} = magnet, announced_trackers) do
    hash = magnet.hash
    hash_hex = Torrent.hex_encoded_hash(hash)
    keys = wait_metadata_peer_keys(hash)

    if keys == [] do
      Logger.debug("[magnet_swarm] no_metadata_peers hash=#{hash_hex}")
      {:error, :no_swarm_metadata_peers}
    else
      peer_count = min(length(keys), max_peers())

      Logger.debug("[magnet_swarm] metadata_start hash=#{hash_hex} swarm_peers=#{peer_count}")

      {result, failures} =
        keys
        |> Enum.take(max_peers())
        |> Task.async_stream(
          fn key -> fetch_from_peer(magnet, key) end,
          max_concurrency: metadata_parallel(),
          ordered: false,
          timeout: peer_timeout_ms(),
          on_timeout: :kill_task
        )
        |> Enum.reduce_while({{:error, :metadata_unavailable}, []}, fn
          {:ok, {:ok, path, private?}}, _acc ->
            {:halt, {{:ok, path, announced_trackers, private?}, []}}

          {:ok, {:error, :info_hash_mismatch}}, _acc ->
            {:halt, {{:error, :info_hash_mismatch}, []}}

          {:ok, {:error, reason}}, {_, failures} ->
            {:cont, {{:error, :metadata_unavailable}, [reason | failures]}}

          {:exit, reason}, {_, failures} ->
            {:cont, {{:error, :metadata_unavailable}, [{:exit, reason} | failures]}}

          _, acc ->
            {:cont, acc}
        end)

      case result do
        {:ok, path, trackers, private?} ->
          Logger.info("[magnet_swarm] metadata_verified hash=#{hash_hex}")
          {:ok, path, trackers, private?}

        {:error, :info_hash_mismatch} = err ->
          err

        {:error, _} ->
          normalized_failures =
            failures |> Enum.reverse() |> Enum.map(&normalize_failure/1) |> Enum.uniq()

          log_metadata_round_exhausted(hash_hex, peer_count, normalized_failures)

          {:error, {:metadata_unavailable, normalized_failures}}
      end
    end
  end

  @spec log_metadata_round_exhausted(String.t(), non_neg_integer(), [term()]) :: :ok
  defp log_metadata_round_exhausted(hash_hex, peer_count, normalized_failures) do
    if normalized_failures != [] do
      Logger.debug(
        "[magnet_swarm] metadata_round_exhausted hash=#{hash_hex} peers_tried=#{peer_count} failures=#{inspect(normalized_failures)}"
      )
    end

    :ok
  end

  @spec fetch_from_peer(Magnet.t(), Peer.key()) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  defp fetch_from_peer(%Magnet{} = magnet, key) do
    endpoint = peer_endpoint(key)

    with {:ok, info} <- safe_metadata_capable(key),
         {:ok, info} <- wait_metadata_ready(key, info),
         true <- metadata_peer?(info) do
      Logger.debug(
        "[magnet_swarm] metadata_peer endpoint=#{endpoint} metadata_size=#{inspect(info.metadata_size)} unchoked=#{info.unchoked?} pid=#{peer_pid(key)}"
      )

      with {:ok, conn} <- Magnet.Connection.open_swarm(key, info),
           result <- Magnet.Connection.fetch_info(conn, magnet.hash),
           :ok <- Magnet.Connection.close(conn) do
        finalize_swarm_fetch(magnet, key, endpoint, result)
      else
        {:error, reason} = error ->
          log_peer_failure(endpoint, :open_swarm, reason, key)
          Magnet.Connection.close_swarm(key)
          error
      end
    else
      false ->
        Logger.debug(
          "[magnet_swarm] metadata_peer_skip endpoint=#{endpoint} reason=no_ut_metadata"
        )

        {:error, :no_ut_metadata}

      {:error, :metadata_size_pending} ->
        Logger.debug(
          "[magnet_swarm] metadata_peer_skip endpoint=#{endpoint} reason=metadata_size_pending"
        )

        {:error, :metadata_size_pending}

      :error ->
        Logger.debug("[magnet_swarm] metadata_peer_skip endpoint=#{endpoint} reason=no_session")
        {:error, :no_metadata_session}

      {:error, reason} ->
        log_peer_failure(endpoint, :metadata_capable, reason, key)
        {:error, reason}
    end
  catch
    :exit, reason ->
      log_peer_failure(peer_endpoint(key), :exit, reason, key)
      Magnet.Connection.close_swarm(key)
      {:error, normalize_peer_error(reason)}
  end

  @spec finalize_swarm_fetch(Magnet.t(), Peer.key(), String.t(), term()) ::
          {:ok, Path.t(), boolean()} | {:error, term()}
  defp finalize_swarm_fetch(magnet, key, endpoint, result) do
    with {:ok, info_map, info_blob} <- result,
         {:ok, path} <- write_torrent(magnet, info_blob) do
      {:ok, path, Magnet.private?(info_map)}
    else
      {:error, reason} ->
        log_peer_failure(endpoint, :fetch_info, reason, key)
        Magnet.Connection.close_swarm(key)
        {:error, reason}

      other ->
        log_peer_failure(endpoint, :fetch_info, other, key)
        Magnet.Connection.close_swarm(key)
        {:error, other}
    end
  end

  @spec safe_metadata_capable(Peer.key()) :: {:ok, map()} | :error | {:error, term()}
  defp safe_metadata_capable(key) do
    case Peer.Controller.metadata_capable(key) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  catch
    :exit, reason -> {:error, normalize_peer_error(reason)}
  end

  @spec log_peer_failure(String.t(), atom(), term(), Peer.key()) :: :ok
  defp log_peer_failure(endpoint, step, reason, key) do
    normalized = normalize_peer_error(reason)

    if normalized in [:peer_died, :noproc] do
      Logger.debug(
        "[magnet_swarm] metadata_peer_died endpoint=#{endpoint} step=#{step} reason=#{inspect(normalized)} pid=#{peer_pid(key)} trying_next_peer"
      )
    else
      Logger.debug(
        "[magnet_swarm] metadata_peer_fail endpoint=#{endpoint} step=#{step} reason=#{inspect(normalized)} pid=#{peer_pid(key)} trying_next_peer"
      )
    end
  end

  @spec normalize_peer_error(term()) :: term()
  defp normalize_peer_error(:noproc), do: :peer_died
  defp normalize_peer_error(:closed), do: :peer_died
  defp normalize_peer_error({:noproc, _}), do: :peer_died
  defp normalize_peer_error(reason), do: reason

  @spec normalize_failure(term()) :: term()
  defp normalize_failure({:exit, reason}), do: normalize_peer_error(reason)
  defp normalize_failure(reason), do: normalize_peer_error(reason)

  @spec metadata_peer?(map()) :: boolean()
  defp metadata_peer?(info) do
    Magnet.Bootstrap.metadata_peer_candidate?(info)
  end

  @spec wait_metadata_ready(Peer.key(), map()) ::
          {:ok, map()} | {:error, :metadata_size_pending | :peer_died}
  defp wait_metadata_ready(key, info) do
    cond do
      Magnet.Bootstrap.metadata_peer_eligible?(info) ->
        {:ok, info}

      Magnet.Bootstrap.metadata_peer_candidate?(info) ->
        # BEP 9: metadata_size in the LTEP handshake is optional; total size is
        # learned from the piece-0 data message (see Connection.download_all_pieces/2).
        # Do not idle-wait for metadata_size or seeder status — the peer will drop
        # the TCP session if we send no ut_metadata traffic.
        {:ok, info}

      true ->
        deadline = System.monotonic_time(:millisecond) + ltep_metadata_wait_ms()
        do_wait_for_ut_metadata(key, info, deadline)
    end
  end

  @spec do_wait_for_ut_metadata(Peer.key(), map(), integer()) ::
          {:ok, map()} | {:error, :metadata_size_pending | :peer_died}
  defp do_wait_for_ut_metadata(key, info, deadline) do
    cond do
      Magnet.Bootstrap.metadata_peer_candidate?(info) ->
        {:ok, info}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :metadata_size_pending}

      true ->
        Process.sleep(wait_poll_ms())

        case safe_metadata_capable(key) do
          {:ok, info} -> do_wait_for_ut_metadata(key, info, deadline)
          :error -> {:error, :peer_died}
        end
    end
  end

  @spec wait_metadata_peer_keys(Torrent.hash()) :: [Peer.key()]
  defp wait_metadata_peer_keys(hash) do
    started_ms = System.monotonic_time(:millisecond)
    deadline = started_ms + wait_for_peers_ms()
    max_deadline = started_ms + wait_max_ms()

    do_wait_metadata_peer_keys(
      hash,
      deadline,
      max_deadline,
      Torrent.Swarm.count(hash),
      started_ms
    )
  end

  @spec do_wait_metadata_peer_keys(
          Torrent.hash(),
          integer(),
          integer(),
          non_neg_integer(),
          integer()
        ) :: [Peer.key()]
  defp do_wait_metadata_peer_keys(hash, deadline, max_deadline, last_count, started_ms) do
    keys = Magnet.Bootstrap.metadata_peer_keys(hash)
    count = Torrent.Swarm.count(hash)
    now = System.monotonic_time(:millisecond)

    deadline =
      if count > last_count do
        extend_wait_deadline(deadline, max_deadline, wait_extend_on_connect_ms())
      else
        deadline
      end

    gather_deadline = started_ms + min_peers_gather_ms()

    cond do
      length(keys) >= min_peers_for_round() ->
        keys

      keys != [] and (now >= gather_deadline or now >= deadline) ->
        keys

      now >= deadline ->
        []

      true ->
        Process.sleep(wait_poll_ms())
        do_wait_metadata_peer_keys(hash, deadline, max_deadline, count, started_ms)
    end
  end

  @spec extend_wait_deadline(integer(), integer(), non_neg_integer()) :: integer()
  defp extend_wait_deadline(deadline, max_deadline, extend_ms) do
    min(deadline + extend_ms, max_deadline)
  end

  @spec peer_endpoint(Peer.key()) :: String.t()
  defp peer_endpoint(key) do
    "peer=#{Peer.log_key(key)}"
  end

  @spec peer_pid(Peer.key()) :: String.t()
  defp peer_pid(key) do
    case GenServer.whereis({:via, Registry, {Registry, {key, Peer.Sender}}}) do
      pid when is_pid(pid) -> inspect(pid)
      _ -> "none"
    end
  catch
    :exit, _ -> "none"
  end

  @spec write_torrent(Magnet.t(), binary()) :: {:ok, Path.t()} | {:error, term()}
  defp write_torrent(%Magnet{} = magnet, info_blob) when is_binary(info_blob) do
    path = Magnet.Fetcher.torrent_path(magnet.hash)
    File.mkdir_p!(Path.dirname(path))
    torrent = Magnet.build_torrent!(magnet, info_blob)
    :ok = File.write(path, torrent)
    {:ok, path}
  end
end

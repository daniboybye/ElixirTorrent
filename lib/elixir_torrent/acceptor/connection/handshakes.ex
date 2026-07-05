defmodule Acceptor.Connection.Handshakes do
  require Logger

  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Task.Supervisor, :start_link,
         [[name: __MODULE__, strategy: :one_for_one, max_restarts: 0]]}
    }
  end

  @default_batch_size 40
  @max_concurrency 10
  @connect_timeout_ms 15_000
  @utp_connect_timeout_ms 10_000
  @handshake_recv_timeout_ms 30_000

  @pstr "BitTorrent protocol"
  @pstrlen <<byte_size(@pstr)>>
  @msg_length 68

  alias Acceptor.BlackList

  def recv(socket) do
    case start_task(fn -> do_recv(socket) end) do
      {:ok, pid} ->
        case safe_controlling_process(socket, pid) do
          :ok -> :ok
          _ -> safe_close(socket)
        end

      {:ok, pid, _} ->
        case safe_controlling_process(socket, pid) do
          :ok -> :ok
          _ -> safe_close(socket)
        end

      _ ->
        safe_close(socket)
        :ok
    end
  end

  @doc false
  @spec recv_utp(UTP.Connection.socket_ref()) :: :ok
  def recv_utp(socket_ref) do
    case start_task(fn -> do_recv(socket_ref) end) do
      {:ok, pid} ->
        case safe_controlling_process(socket_ref, pid) do
          :ok -> :ok
          _ -> safe_close(socket_ref)
        end

      _ ->
        safe_close(socket_ref)
        :ok
    end
  end

  @spec handshakes(list(Peer.t()), Torrent.hash()) :: :ok
  def handshakes(peers, hash),
    do: Enum.each(peers, &start_task(fn -> do_send(&1, hash) end))

  @doc false
  @spec dial_peers([Peer.t()], Torrent.hash()) ::
          {non_neg_integer(), map(), [{Peer.t(), term()}]}
  def dial_peers(peers, hash) when is_binary(hash) and byte_size(hash) == 20 do
    peers_to_dial = select_peers_to_dial(peers, hash)
    hash_hex = Torrent.hex_encoded_hash(hash)
    connected = Torrent.Swarm.count(hash)

    cond do
      peers == [] ->
        {0, %{}, []}

      peers_to_dial == [] ->
        Logger.info(
          "[peer_dial] hash=#{hash_hex} batch=#{length(peers)} to_dial=0 connected=#{connected} reason=all_filtered"
        )

        {0, %{}, []}

      true ->
        {ok_count, failures, failed_peers} = dial_peers_async(peers_to_dial, hash)

        Logger.info(
          "[peer_dial] hash=#{hash_hex} batch=#{length(peers)} to_dial=#{length(peers_to_dial)} ok=#{ok_count} failed=#{inspect(failures)} connected=#{Torrent.Swarm.count(hash)}"
        )

        {ok_count, failures, failed_peers}
    end
  end

  @doc false
  @spec handshakes_sync(list(Peer.t()), Torrent.hash()) :: :ok
  def handshakes_sync(peers, hash) do
    _ = dial_peers(peers, hash)
    :ok
  end

  @doc false
  @spec select_peers_to_dial(list(Peer.t()), Torrent.hash(), non_neg_integer()) :: [Peer.t()]
  def select_peers_to_dial(peers, hash, batch \\ @default_batch_size)
      when is_binary(hash) and byte_size(hash) == 20 and is_integer(batch) and batch > 0 do
    min_count = if Torrent.Swarm.count(hash) < 20, do: batch, else: 0

    peers
    |> Enum.filter(&connectable_peer?/1)
    |> Peer.DialBackoff.filter(hash, min_count)
    |> Enum.reject(&already_connected?(&1, hash))
    |> Enum.take(batch)
  end

  @spec already_connected?(Peer.t(), Torrent.hash()) :: boolean()
  defp already_connected?(%Peer{id: id, ip: ip, port: port}, hash) do
    Peer.Endpoints.registered?(hash, ip, port) or
      (is_binary(id) and Peer.exists?(%Peer{ip: ip, port: port, id: id}, hash))
  end

  @spec dial_peers_async([Peer.t()], Torrent.hash()) ::
          {non_neg_integer(), map(), [{Peer.t(), term()}]}
  defp dial_peers_async(peers, hash) do
    peers
    |> Task.async_stream(
      fn peer -> {peer, do_send(peer, hash)} end,
      max_concurrency: @max_concurrency,
      timeout: @connect_timeout_ms + @utp_connect_timeout_ms + @handshake_recv_timeout_ms + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({0, %{}, []}, fn
      {:ok, {_peer, :ok}}, {ok, failures, failed} ->
        {ok + 1, failures, failed}

      {:ok, {peer, {:error, reason}}}, {ok, failures, failed} ->
        {ok, increment_failure(failures, reason), [{peer, reason} | failed]}

      {:exit, reason}, {ok, failures, failed} ->
        {ok, increment_failure(failures, reason), failed}
    end)
  end

  @spec increment_failure(map(), term()) :: map()
  defp increment_failure(failures, reason),
    do: Map.update(failures, reason, 1, &(&1 + 1))

  defp start_task(fun),
    do: Task.Supervisor.start_child(__MODULE__, fun)

  @spec do_send(Peer.t(), Torrent.hash()) :: :ok | {:error, term()}
  defp do_send(%Peer{} = peer, hash) do
    started = System.monotonic_time(:millisecond)

    result =
      if connectable_peer?(peer) do
        with false <- already_connected?(peer, hash),
             {:ok, socket, transport} <- connect_peer(peer, started) do
          case handshake_peer(peer, hash, socket, transport, started) do
            :ok ->
              :ok

            {:error, _} = error ->
              safe_close(socket)
              error
          end
        else
          true -> {:error, :already_connected}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :not_connectable}
      end

    case result do
      :ok ->
        result

      {:error, reason} = error ->
        log_dial(peer, reason, started, nil)
        error
    end
  end

  defp handshake_peer(peer, hash, socket, transport, started) do
    with :ok <- send_msg(socket, hash),
         :ok <- log_handshake_sent(peer, transport),
         {^hash, peer_id, reserved} <- recv_msg(socket),
         :ok <- log_handshake_recv(peer, transport),
         false <- BlackList.member?(peer_id),
         :ok <- add_peer(hash, peer_id, reserved, socket, peer) do
      log_dial(peer, :ok, started, transport)
      :ok
    else
      true -> {:error, :already_connected}
      {:error, reason} -> {:error, reason}
      false -> {:error, :rejected}
      _ -> {:error, :handshake_failed}
    end
  end

  defp log_dial(%Peer{ip: ip, port: port}, outcome, started_ms, transport) do
    ms = System.monotonic_time(:millisecond) - started_ms

    case outcome do
      :ok ->
        Logger.debug(
          "[peer_dial] ok endpoint=#{inspect({ip, port})} transport=#{transport} ms=#{ms}"
        )

      reason ->
        Logger.debug(
          "[peer_dial] fail endpoint=#{inspect({ip, port})} reason=#{inspect(reason)} ms=#{ms}"
        )
    end
  end

  defp log_handshake_sent(%Peer{ip: ip, port: port}, :utp) do
    Logger.info("[peer_dial] utp_handshake_sent endpoint=#{inspect({ip, port})}")
    :ok
  end

  defp log_handshake_sent(_peer, _transport), do: :ok

  defp log_handshake_recv(%Peer{ip: ip, port: port}, :utp) do
    Logger.info("[peer_dial] utp_handshake_recv endpoint=#{inspect({ip, port})}")
    :ok
  end

  defp log_handshake_recv(%Peer{ip: ip, port: port}, transport) do
    Logger.debug(
      "[peer_dial] handshake_recv endpoint=#{inspect({ip, port})} transport=#{transport}"
    )

    :ok
  end

  @spec connect_peer(Peer.t(), integer()) ::
          {:ok, Peer.Transport.socket(), :tcp | :utp} | {:error, term()}
  defp connect_peer(%Peer{ip: ip, port: port}, _started_ms) do
    opts = Acceptor.tcp_socket_options(family_for_ip(ip))

    # TCP-first (21:10 path). uTP is additive fallback only — never blocks or
    # cancels a TCP connect that already succeeded (parallel yield_many did both).
    case safe_connect(ip, port, opts) do
      {:ok, socket} ->
        :ok = Acceptor.apply_tcp_performance(socket)
        Logger.info("[peer_dial] connect_won transport=tcp endpoint=#{inspect({ip, port})}")
        {:ok, socket, :tcp}

      {:error, tcp_reason} ->
        case safe_utp_connect(ip, port) do
          {:ok, socket} ->
            Logger.info("[peer_dial] connect_won transport=utp endpoint=#{inspect({ip, port})}")
            {:ok, socket, :utp}

          {:error, _utp_reason} ->
            {:error, tcp_reason}
        end
    end
  end

  defp safe_utp_connect(ip, port) do
    try do
      UTP.Dispatcher.connect(ip, port, [], @utp_connect_timeout_ms)
    catch
      :exit, _ -> {:error, :timeout}
    end
  end

  @spec connectable_peer?(Peer.t()) :: boolean()
  def connectable_peer?(%Peer{ip: ip, port: port}) do
    valid_ip?(ip) and routable_ip?(ip) and is_integer(port) and port > 0 and port <= 65535
  end

  @spec routable_ip?(:inet.ip_address()) :: boolean()
  def routable_ip?({0, 0, 0, 0}), do: false
  def routable_ip?({127, _, _, _}), do: false
  def routable_ip?({169, 254, _, _}), do: false
  def routable_ip?({a, _, _, _}) when a >= 224 and a <= 239, do: false
  def routable_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false
  def routable_ip?(ip) when is_tuple(ip), do: true

  @spec valid_ip?(:inet.ip_address()) :: boolean()
  defp valid_ip?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d),
       do: true

  defp valid_ip?({a, b, c, d, e, f, g, h})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
              is_integer(e) and is_integer(f) and is_integer(g) and is_integer(h),
       do: true

  defp valid_ip?(_), do: false

  @spec safe_connect(:inet.ip_address(), :inet.port_number(), list()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  defp safe_connect(ip, port, opts) do
    case :gen_tcp.connect(ip, port, opts, @connect_timeout_ms) do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        error
    end
  rescue
    ArgumentError -> {:error, :badarg}
  catch
    :error, :badarg -> {:error, :badarg}
  end

  @spec family_for_ip(:inet.ip_address()) :: :inet | :inet6
  defp family_for_ip({_, _, _, _}), do: :inet
  defp family_for_ip({_, _, _, _, _, _, _, _}), do: :inet6

  @spec do_recv(Peer.Transport.socket()) :: :ok
  defp do_recv(socket) do
    with {hash, peer_id, reserved} <- recv_msg(socket),
         false <- BlackList.member?(peer_id),
         true <- Torrent.has_hash?(hash),
         :ok <- send_msg(socket, hash),
         :ok <- add_peer(hash, peer_id, reserved, socket, peer_endpoint(nil, socket)) do
      :ok
    else
      _ -> safe_close(socket)
    end
  end

  @spec transfer_controlling_process(Peer.Transport.socket(), pid()) ::
          :ok | {:error, term()}
  defp transfer_controlling_process(socket, pid) do
    case safe_controlling_process(socket, pid) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec safe_controlling_process(Peer.Transport.socket(), pid()) :: :ok | {:error, term()}
  defp safe_controlling_process(socket, pid) do
    case Peer.Transport.controlling_process(socket, pid) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp add_peer(hash, peer_id, reserved, socket, %Peer{} = peer) do
    add_peer(hash, peer_id, reserved, socket, peer_endpoint(peer, socket))
  end

  defp add_peer(hash, peer_id, reserved, socket, endpoint) do
    case Torrent.add_peer(hash, peer_id, reserved, socket) do
      {:ok, pid} ->
        handoff_socket(hash, pid, socket, endpoint)

      {:ok, pid, _} ->
        handoff_socket(hash, pid, socket, endpoint)

      {:error, :max_peers} ->
        safe_close(socket)
        {:error, :max_peers}

      _ ->
        safe_close(socket)
        {:error, :add_peer_failed}
    end
  end

  @spec handoff_socket(Torrent.hash(), pid(), Peer.Transport.socket(), term()) ::
          :ok | {:error, term()}
  defp handoff_socket(hash, peer_supervisor, socket, endpoint) do
    with sender when is_pid(sender) <- Peer.sender_pid(peer_supervisor),
         key when is_tuple(key) <- Peer.get_key(peer_supervisor),
         :ok <- register_endpoint(hash, endpoint, peer_supervisor),
         :ok <- transfer_controlling_process(socket, sender),
         :ok <- safe_activate(key) do
      Logger.info(
        "[peer_handoff] ok hash=#{Torrent.hex_encoded_hash(hash)} endpoint=#{inspect(endpoint)}"
      )

      notify_current_piece(hash, peer_supervisor)
      :ok
    else
      reason ->
        log_handoff_failure(hash, endpoint, reason)

        safe_close(socket)
        Peer.disconnect(peer_supervisor)
        {:error, :socket_handoff_failed}
    end
  end

  @spec safe_activate(Peer.key()) :: :ok | {:error, term()}
  defp safe_activate(key) do
    Peer.Sender.activate(key)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec log_handoff_failure(Torrent.hash(), term(), term()) :: :ok
  defp log_handoff_failure(hash, endpoint, reason) do
    msg =
      "[peer_handoff] failed hash=#{Torrent.hex_encoded_hash(hash)} endpoint=#{inspect(endpoint)} reason=#{inspect(reason)}"

    if benign_handoff_failure?(reason) do
      Logger.debug(msg)
    else
      Logger.warning(msg)
    end
  end

  @spec benign_handoff_failure?(term()) :: boolean()
  defp benign_handoff_failure?({:error, :noproc}), do: true
  defp benign_handoff_failure?({:error, :normal}), do: true
  defp benign_handoff_failure?({:error, :max_peers}), do: true
  defp benign_handoff_failure?({:error, {:noproc, _}}), do: true
  defp benign_handoff_failure?({:error, {:normal, _}}), do: true
  defp benign_handoff_failure?({:error, {:shutdown, _}}), do: true
  defp benign_handoff_failure?(:noproc), do: true
  defp benign_handoff_failure?(_), do: false

  @spec register_endpoint(Torrent.hash(), {:inet.ip_address(), :inet.port_number()} | nil, pid()) ::
          :ok
  defp register_endpoint(_hash, nil, _pid), do: :ok

  defp register_endpoint(hash, {ip, port}, pid),
    do: Peer.Endpoints.register(hash, ip, port, pid)

  @spec peer_endpoint(Peer.t() | nil, Peer.Transport.socket()) ::
          {:inet.ip_address(), :inet.port_number()} | nil
  defp peer_endpoint(%Peer{ip: ip, port: port}, _socket), do: {ip, port}

  defp peer_endpoint(nil, socket) do
    case Peer.Transport.peername(socket) do
      {:ok, {ip, port}} -> {ip, port}
      {:error, _} -> nil
    end
  end

  @spec notify_current_piece(Torrent.hash(), pid()) :: :ok
  defp notify_current_piece(hash, pid) do
    try do
      case Torrent.get(hash, :peer_status) do
        index when is_integer(index) -> Peer.interested(pid, index)
        _ -> :ok
      end
    catch
      :exit, _ -> :ok
    end
  end

  defp send_msg(socket, hash) do
    msg = [@pstrlen, @pstr, Peer.reserved(), hash, Peer.id()]

    case Peer.Transport.send(socket, msg) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recv_msg(Peer.Transport.socket()) ::
          {binary(), binary(), Peer.reserved()} | {:error, term()}
  defp recv_msg(socket) do
    case Peer.Transport.recv(socket, @msg_length, @handshake_recv_timeout_ms) do
      {:ok,
       <<@pstrlen, @pstr, reserved::bytes-size(8), hash::bytes-size(20), peer_id::bytes-size(20)>>} ->
        {hash, peer_id, reserved}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_handshake}
    end
  end

  @spec safe_close(Peer.Transport.socket()) :: :ok
  defp safe_close({:utp, _} = socket) do
    Peer.Transport.close(socket)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_close(socket) when is_port(socket) do
    :gen_tcp.close(socket)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end

defmodule Acceptor.Connection.Handshakes do
  @moduledoc """
  Task supervisor and helpers for TCP/uTP dials, MSE, and BEP 3/10 handshakes.
  """

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
  # Wider dial pipeline: at 10 a 40-peer batch serialized into 4 waves, and a
  # wave of dead IPv6 peers stalled the whole batch for a full connect timeout.
  @max_concurrency 20
  # When a family is proven wasteful (see Peer.DialStats) we still dial a handful
  # per batch: enough to notice the family recovering (a network/path change) and
  # lift the throttle, cheap enough that the wasted connect-timeouts don't matter.
  @dial_probe 4
  # Family-aware connect timeout. IPv4, when reachable, completes fast, so 10s
  # sheds dead v4 candidates quickly. IPv6 is our primary inbound path under
  # CGNAT and its handshakes run measurably slower (higher-latency paths);
  # measured: cutting v6 to 10s dropped v6 connect success 7.3%→2.7%, so v6
  # keeps the original 15s.
  @connect_timeout_ms 10_000
  @connect_timeout_v6_ms 15_000
  @utp_connect_timeout_ms 10_000
  @handshake_recv_timeout_ms 30_000

  @pstr "BitTorrent protocol"
  @pstrlen <<byte_size(@pstr)>>
  @msg_length 68

  # MSE/PE (BEP-adjacent). Inbound is always auto-detected (we accept both
  # plaintext and encrypted peers). Outbound is :prefer — try the encrypted MSE
  # handshake first, fall back to plaintext on {:error, {:mse, _}}.
  #
  # Enabling :prefer previously regressed real-peer dials to :invalid_handshake:
  # MSE.Handshake.initiate read the peer's crypto_select but ignored it, so a peer
  # that selected plaintext had its (cleartext) data stream RC4-decrypted into
  # garbage. Fixed: initiate now honours crypto_select (rc4 → keep ciphers,
  # plaintext → raw socket). Verified against live peers: :invalid_handshake
  # stayed 0 across 100+ dial batches with :prefer active (was 346 before).
  @mse_outbound :prefer

  alias Acceptor.BlackList
  alias Peer.MSE.Handshake

  def recv(socket) do
    case recv_task(socket) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc false
  @spec recv_task(Peer.Transport.socket()) :: {:ok, pid()} | {:error, term()}
  def recv_task(socket) do
    case start_task(fn -> do_recv(socket) end) do
      {:ok, pid} ->
        case safe_controlling_process(socket, pid) do
          :ok -> {:ok, pid}
          error -> close_task_socket(socket, pid, error)
        end

      {:ok, pid, _} ->
        case safe_controlling_process(socket, pid) do
          :ok -> {:ok, pid}
          error -> close_task_socket(socket, pid, error)
        end

      error ->
        safe_close(socket)
        {:error, error}
    end
  end

  defp close_task_socket(socket, pid, error) do
    safe_close(socket)
    Process.exit(pid, :shutdown)
    {:error, error}
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
  def handshakes(peers, hash) do
    :ok = Peer.ConnectionManager.offer_peers(hash, peers)
    Peer.ConnectionManager.kick(hash)
  end

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
        Logger.debug(
          "[peer_dial] hash=#{hash_hex} batch=#{length(peers)} to_dial=0 connected=#{connected} reason=all_filtered"
        )

        {0, %{}, []}

      true ->
        # split_with puts truthy (ipv6) first; keep the labels matching reality so
        # the dial-composition log isn't inverted (it once read v4/v6 backwards).
        {v6, v4} = Enum.split_with(peers_to_dial, &ipv6_peer?/1)

        Logger.debug(
          "[peer_dial] hash=#{hash_hex} to_dial v4=#{length(v4)} v6=#{length(v6)} total=#{length(peers_to_dial)}"
        )

        {ok_count, failures, failed_peers, fam_stats} = dial_peers_async(peers_to_dial, hash)
        record_family_stats(hash, fam_stats)

        Logger.debug(
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
    # Hoist the listen port out of the per-candidate filter — `Acceptor.port/0`
    # is a `GenServer.call/2` on the singleton Acceptor.Connection.Handler, so
    # doing it inside `Enum.filter/2` cost one round-trip per candidate.
    listen_port = Acceptor.port()

    peers
    |> Enum.filter(&connectable_peer?(&1, listen_port))
    |> Peer.DialBackoff.filter(hash, min_count)
    |> Enum.reject(&already_connected?(&1, hash))
    |> take_dial_batch(batch, hash)
  end

  # Compose the dial batch from the two address families, throttling whichever one
  # is *proven wasteful* for this torrent (measured near-zero outbound success —
  # see Peer.DialStats). The throttled family gets only a small probe and the rest
  # of the batch is filled from the other family. Under CGNAT+global-v6 the dead
  # family is IPv4 (peers behind NAT we can't reach, and no inbound v4 to receive
  # them); on a host where v6 is the dead path the exact same machinery throttles
  # v6 instead. The judgment is per-family and re-measured continuously, so nothing
  # here is hardcoded to a family.
  # When connected peers are scarce (< 12), prefer IPv6 candidates first. On this
  # host v6 outbound dials succeed ~25% vs v4 ~1.3% under CGNAT; balanced 50/50
  # wastes half the batch on timeouts while v6 peers sit in the queue. DialStats
  # throttle still applies when a family is proven dead — this only reorders when
  # both families have live candidates. Outside critical tier, `prefer_inet6?/1`
  # biases ~75/25 when live stats show v6 clearly wins. Sole-family v6 still gets
  # a full batch; sole-family v4 is capped to a probe when wasteful *or* when
  # connected is 1..11 (still critical) so DialBackoff exhaustion of v6 does not
  # oscillate into 40× dead v4 dials before the next replenish wave. At
  # connected==0 (fresh tracker kick) use the full batch — capping to @dial_probe
  # left 5–7 tracker peers stuck at 4 while same-/64 v6 self-echoes were filtered.
  @critical_connected_threshold 12

  @spec take_dial_batch([Peer.t()], non_neg_integer(), Torrent.hash()) :: [Peer.t()]
  defp take_dial_batch(peers, batch, hash) do
    {v6, v4} = Enum.split_with(peers, &ipv6_peer?/1)
    critical? = Torrent.Swarm.count(hash) < @critical_connected_threshold
    v4_wasteful? = v4 != [] and Peer.DialStats.throttle_worthy?(hash, :inet)
    v6_wasteful? = v6 != [] and Peer.DialStats.throttle_worthy?(hash, :inet6)

    if v4 == [] or v6 == [] do
      take_dial_batch_one_family(v4, v6, batch, hash, v4_wasteful?, critical?)
    else
      take_dial_batch_dual(v4, v6, batch, hash, critical?, v4_wasteful?, v6_wasteful?)
    end
  end

  @spec take_dial_batch_dual(
          [Peer.t()],
          [Peer.t()],
          non_neg_integer(),
          Torrent.hash(),
          boolean(),
          boolean(),
          boolean()
        ) :: [Peer.t()]
  defp take_dial_batch_dual(v4, v6, batch, hash, critical?, v4_wasteful?, v6_wasteful?) do
    cond do
      critical? ->
        v6_take = Enum.take(v6, batch)
        v6_take ++ Enum.take(v4, batch - length(v6_take))

      Peer.DialStats.prefer_inet6?(hash) ->
        v6_heavy(v4, v6, batch)

      v4_wasteful? and not v6_wasteful? ->
        throttle_family(v4, v6, batch)

      v6_wasteful? and not v4_wasteful? ->
        throttle_family(v6, v4, batch)

      true ->
        balanced(v4, v6, batch)
    end
  end

  @spec take_dial_batch_one_family(
          [Peer.t()],
          [Peer.t()],
          non_neg_integer(),
          Torrent.hash(),
          boolean(),
          boolean()
        ) :: [Peer.t()]
  defp take_dial_batch_one_family(v4, v6, batch, hash, v4_wasteful?, critical?) do
    sole_v4_probe? =
      v4 != [] and v6 == [] and Torrent.Swarm.count(hash) > 0 and (v4_wasteful? or critical?)

    if sole_v4_probe? do
      # Under CGNAT, sole v4 with no v6 candidates must not burn the whole
      # dial budget on connect timeouts when v4 is proven wasteful *and* we
      # already have peers, or when connected is 1..11 (critical) so
      # DialBackoff may have temporarily exhausted v6 — cap to a probe so
      # slots stay free for the next replenish wave. At connected==0 after a
      # tracker response, always dial the full batch (lottery width): prior
      # timeout waves may have marked v4 wasteful, but every offered peer may
      # still be the first connect.
      Enum.take(v4, min(@dial_probe, batch))
    else
      # Sole v6, or non-critical sole v4 not yet proven wasteful: no other
      # family to spend slots on, so use the full batch — DialBackoff spaces
      # re-dials.
      Enum.take(v4 ++ v6, batch)
    end
  end

  # Throttled family `dead` contributes at most a small probe; `alt` fills the rest
  # of the batch. Deliberately do NOT backfill leftover slots with more `dead` —
  # leaving a slot empty beats spending a connect timeout on a peer we expect to
  # fail. (`alt` is placed first so the healthy family is dialed before the probe.)
  @spec throttle_family([Peer.t()], [Peer.t()], non_neg_integer()) :: [Peer.t()]
  defp throttle_family(dead, alt, batch) do
    probe = Enum.take(dead, min(@dial_probe, batch))
    alt_take = Enum.take(alt, batch - length(probe))
    alt_take ++ probe
  end

  # Both families are viable: fill up to `batch` slots taking roughly half from
  # each and backfilling the remainder from whichever still has candidates, so we
  # never leave a dial slot idle while peers remain. Deliberately family-neutral —
  # which family connects better is host- and time-specific (v6 wins here under
  # CGNAT; a host with inbound v4 could be the reverse), and the throttle above
  # already handles a genuinely dead family, so this path stays unbiased.
  @spec balanced([Peer.t()], [Peer.t()], non_neg_integer()) :: [Peer.t()]
  defp balanced(v4, v6, batch) do
    {v4_head, v4_rest} = Enum.split(v4, div(batch, 2))
    v6_take = Enum.take(v6, batch - length(v4_head))
    v4_head ++ v6_take ++ Enum.take(v4_rest, batch - length(v4_head) - length(v6_take))
  end

  # ~75% v6 / ~25% v4 when live DialStats show v6 clearly outperforms v4. Keeps
  # at least @dial_probe v4 slots (when v4 has candidates) so a recovering v4 path
  # is still sampled; backfills from whichever family still has queue depth.
  @spec v6_heavy([Peer.t()], [Peer.t()], non_neg_integer()) :: [Peer.t()]
  defp v6_heavy(v4, v6, batch) do
    v4_quota = max(@dial_probe, div(batch, 4))
    {v4_head, v4_rest} = Enum.split(v4, min(v4_quota, batch))
    v6_take = Enum.take(v6, batch - length(v4_head))
    v4_head ++ v6_take ++ Enum.take(v4_rest, batch - length(v4_head) - length(v6_take))
  end

  @spec ipv6_peer?(Peer.t()) :: boolean()
  defp ipv6_peer?(%Peer{ip: ip}), do: tuple_size(ip) == 8

  @spec already_connected?(Peer.t(), Torrent.hash()) :: boolean()
  defp already_connected?(%Peer{id: id, ip: ip, port: port}, hash) do
    Peer.Endpoints.registered?(hash, ip, port) or
      (is_binary(id) and Peer.exists?(%Peer{ip: ip, port: port, id: id}, hash))
  end

  @typep fam_stats :: %{
           inet: {non_neg_integer(), non_neg_integer()},
           inet6: {non_neg_integer(), non_neg_integer()}
         }

  @spec dial_peers_async([Peer.t()], Torrent.hash()) ::
          {non_neg_integer(), map(), [{Peer.t(), term()}], fam_stats()}
  defp dial_peers_async(peers, hash) do
    peers
    |> Task.async_stream(
      fn peer ->
        try do
          {peer, do_send(peer, hash)}
        catch
          :exit, reason -> {peer, {:error, reason}}
          kind, reason -> {peer, {:error, {kind, reason}}}
        end
      end,
      max_concurrency: @max_concurrency,
      timeout:
        @connect_timeout_v6_ms + @utp_connect_timeout_ms + @handshake_recv_timeout_ms + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({0, %{}, [], %{inet: {0, 0}, inet6: {0, 0}}}, fn
      {:ok, {peer, :ok}}, {ok, failures, failed, fam} ->
        {ok + 1, failures, failed, bump_fam(fam, peer, :ok)}

      {:ok, {peer, {:error, reason}}}, {ok, failures, failed, fam} ->
        {ok, increment_failure(failures, reason), [{peer, reason} | failed],
         bump_fam_failure(fam, peer, reason)}

      {:exit, reason}, {ok, failures, failed, fam} ->
        {ok, increment_failure(failures, reason), failed, fam}
    end)
  end

  @spec increment_failure(map(), term()) :: map()
  defp increment_failure(failures, reason),
    do: Map.update(failures, reason, 1, &(&1 + 1))

  # Dial outcome → Peer.DialStats family bump. :socket_handoff_failed is emitted
  # only after TCP/uTP connect and the BitTorrent handshake succeeded; the peer
  # proved reachable and local OTP churn (register/handoff/activate) failed.
  # Count that as a family :ok so v4/v6 yield isn't poisoned by our own process
  # wiring. :already_connected / :not_connectable are neutral (:skip).
  @doc false
  @spec dial_reachability_outcome(term()) :: :ok | :skip | :fail
  def dial_reachability_outcome(:socket_handoff_failed), do: :ok

  def dial_reachability_outcome(reason) when reason in [:already_connected, :not_connectable],
    do: :skip

  def dial_reachability_outcome(_reason), do: :fail

  @spec bump_fam_failure(fam_stats(), Peer.t(), term()) :: fam_stats()
  defp bump_fam_failure(fam, peer, reason) do
    case dial_reachability_outcome(reason) do
      :skip -> fam
      outcome -> bump_fam(fam, peer, outcome)
    end
  end

  @spec bump_fam(fam_stats(), Peer.t(), :ok | :fail) :: fam_stats()
  defp bump_fam(fam, peer, outcome) do
    family = if ipv6_peer?(peer), do: :inet6, else: :inet

    Map.update!(fam, family, fn
      {ok, fail} when outcome == :ok -> {ok + 1, fail}
      {ok, fail} -> {ok, fail + 1}
    end)
  end

  @spec record_family_stats(Torrent.hash(), fam_stats()) :: :ok
  defp record_family_stats(hash, fam) do
    Enum.each(fam, fn {family, {ok, fail}} ->
      Peer.DialStats.record(hash, family, ok, fail)
    end)
  end

  defp start_task(fun),
    do: Task.Supervisor.start_child(__MODULE__, fun)

  @doc false
  @spec dial_utp_and_handshake(Peer.t(), Torrent.hash()) :: :ok | {:error, term()}
  def dial_utp_and_handshake(%Peer{ip: ip, port: port} = peer, hash) do
    started = System.monotonic_time(:millisecond)

    if already_connected?(peer, hash) do
      {:error, :already_connected}
    else
      # Hole-punched uTP connections stay plaintext — the punch is the hard part.
      with {:ok, socket} <- safe_utp_connect(ip, port) do
        handshake_peer(peer, hash, socket, :utp, started, :plaintext)
      end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec do_send(Peer.t(), Torrent.hash()) :: :ok | {:error, term()}
  defp do_send(%Peer{} = peer, hash) do
    started = System.monotonic_time(:millisecond)

    result =
      if connectable_peer?(peer) do
        case already_connected?(peer, hash) do
          true -> {:error, :already_connected}
          false -> dial_and_handshake(peer, hash, started, mse_outbound())
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

  # Runtime config (also flippable without a recompile) so the type checker
  # doesn't fold the value and flag the branch the default doesn't take.
  @spec mse_outbound() :: :plaintext | :prefer
  defp mse_outbound, do: Application.get_env(:elixir_torrent, :mse_outbound, @mse_outbound)

  # Connect + handshake, with a one-shot plaintext fallback: if MSE was preferred
  # but the encrypted handshake itself failed (peer speaks plaintext only, or
  # reset it), reconnect once in the clear so we don't lose that peer.
  @spec dial_and_handshake(Peer.t(), Torrent.hash(), integer(), :plaintext | :prefer) ::
          :ok | {:error, term()}
  defp dial_and_handshake(peer, hash, started, mode) do
    with {:ok, socket, transport} <- connect_peer(peer, hash, started) do
      case handshake_peer(peer, hash, socket, transport, started, mode) do
        :ok ->
          :ok

        {:error, {:mse, _}} when mode == :prefer ->
          safe_close(socket)
          dial_and_handshake(peer, hash, started, :plaintext)

        {:error, _} = error ->
          safe_close(socket)
          error
      end
    end
  end

  # For outbound MSE we send our BitTorrent handshake as the encrypted IA and get
  # back a cipher-wrapped socket; otherwise we send the plaintext handshake below.
  @spec outbound_socket(Peer.Transport.socket(), Torrent.hash(), :plaintext | :prefer) ::
          {:ok, Peer.Transport.socket(), boolean()} | {:error, term()}
  defp outbound_socket(socket, hash, mode) do
    case mode do
      :prefer ->
        case Handshake.initiate(socket, hash, handshake_bytes(hash)) do
          # Peer selected RC4: wrap the socket so the rest of the stream is
          # encrypted. Our BT handshake already went out as the encrypted IA.
          {:ok, %{mode: :rc4} = ciphers} ->
            {:ok, Peer.Transport.wrap(socket, Map.take(ciphers, [:recv, :send])), false}

          # Peer completed the obfuscated MSE handshake but chose plaintext for the
          # data stream: use the RAW socket (do NOT keep RC4-ing it — that was the
          # regression). IA already carried our handshake, so don't resend it.
          {:ok, %{mode: :plaintext}} ->
            {:ok, socket, false}

          {:error, reason} ->
            {:error, {:mse, reason}}
        end

      _ ->
        {:ok, socket, true}
    end
  end

  defp handshake_peer(peer, hash, socket, transport, started, mode) do
    with {:ok, socket, send_plain?} <- outbound_socket(socket, hash, mode),
         :ok <- if(send_plain?, do: send_msg(socket, hash), else: :ok),
         :ok <- log_handshake_sent(peer, transport),
         {^hash, peer_id, reserved} <- recv_msg(socket),
         :ok <- log_handshake_recv(peer, transport),
         :ok <- blacklist_ok(peer_id),
         :ok <- add_peer(hash, peer_id, reserved, socket, peer, :outbound) do
      log_dial(peer, :ok, started, transport)
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  @spec blacklist_ok(Peer.id()) :: :ok | {:error, :already_connected}
  defp blacklist_ok(peer_id) do
    if BlackList.member?(peer_id), do: {:error, :already_connected}, else: :ok
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
    Logger.debug("[peer_dial] utp_handshake_sent endpoint=#{inspect({ip, port})}")
    :ok
  end

  defp log_handshake_sent(_peer, _transport), do: :ok

  defp log_handshake_recv(%Peer{ip: ip, port: port}, :utp) do
    Logger.debug("[peer_dial] utp_handshake_recv endpoint=#{inspect({ip, port})}")
    :ok
  end

  defp log_handshake_recv(%Peer{ip: ip, port: port}, transport) do
    Logger.debug(
      "[peer_dial] handshake_recv endpoint=#{inspect({ip, port})} transport=#{transport}"
    )

    :ok
  end

  @doc false
  @spec dial_transports(:inet.ip_address(), Torrent.hash()) :: [:tcp | :utp, ...]
  def dial_transports(ip, hash) when is_binary(hash) and byte_size(hash) == 20 do
    # Default TCP-first: uTP is additive fallback only — never blocks a TCP connect
    # that already succeeded (parallel yield_many did both).
    #
    # When IPv4 dials are proven wasteful for this torrent (Peer.DialStats), try
    # uTP before TCP. Under CGNAT, dead v4 TCP often means the peer is NAT'd with
    # no open TCP port; uTP/UDP may still punch through. Don't uTP-first when v4
    # is healthy — TCP-only peers would pay an extra uTP timeout.
    if tuple_size(ip) == 4 and Peer.DialStats.throttle_worthy?(hash, :inet) do
      [:utp, :tcp]
    else
      [:tcp, :utp]
    end
  end

  @spec connect_peer(Peer.t(), Torrent.hash(), integer()) ::
          {:ok, Peer.Transport.socket(), :tcp | :utp} | {:error, term()}
  defp connect_peer(%Peer{ip: ip, port: port}, hash, _started_ms) do
    opts = Acceptor.connect_options(family_for_ip(ip))
    connect_transports(dial_transports(ip, hash), ip, port, opts)
  end

  @spec connect_transports([:tcp | :utp], :inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, Peer.Transport.socket(), :tcp | :utp} | {:error, term()}
  defp connect_transports(transports, ip, port, opts) do
    connect_transports(transports, ip, port, opts, nil)
  end

  defp connect_transports([], _ip, _port, _opts, first_reason) do
    {:error, first_reason}
  end

  defp connect_transports([transport | rest], ip, port, opts, first_reason) do
    case connect_transport(transport, ip, port, opts) do
      {:ok, _socket, _transport} = ok ->
        ok

      {:error, reason} ->
        first_reason = first_reason || reason
        connect_transports(rest, ip, port, opts, first_reason)
    end
  end

  @spec connect_transport(:tcp | :utp, :inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, Peer.Transport.socket(), :tcp | :utp} | {:error, term()}
  defp connect_transport(:tcp, ip, port, opts) do
    case safe_connect(ip, port, opts) do
      {:ok, socket} ->
        :ok = Acceptor.apply_tcp_performance(socket)
        Logger.debug("[peer_dial] connect_won transport=tcp endpoint=#{inspect({ip, port})}")
        {:ok, socket, :tcp}

      {:error, _} = error ->
        error
    end
  end

  defp connect_transport(:utp, ip, port, _opts) do
    case safe_utp_connect(ip, port) do
      {:ok, socket} ->
        Logger.debug("[peer_dial] connect_won transport=utp endpoint=#{inspect({ip, port})}")
        {:ok, socket, :utp}

      {:error, _} = error ->
        error
    end
  end

  defp safe_utp_connect(ip, port) do
    if ipv6_dialable?(ip) do
      try do
        UTP.Dispatcher.connect(ip, port, [], @utp_connect_timeout_ms)
      catch
        :exit, _ -> {:error, :timeout}
      end
    else
      {:error, :eafnosupport}
    end
  end

  @spec connectable_peer?(Peer.t()) :: boolean()
  def connectable_peer?(%Peer{} = peer) do
    connectable_peer?(peer, Acceptor.port())
  end

  @doc false
  @spec connectable_peer?(Peer.t(), :inet.port_number()) :: boolean()
  def connectable_peer?(%Peer{ip: ip, port: port}, listen_port) do
    not local_endpoint?(ip, port, listen_port) and valid_ip?(ip) and routable_ip?(ip) and
      ipv6_dialable?(ip) and is_integer(port) and port > 0 and port <= 65_535
  end

  @doc false
  @spec local_endpoint?(:inet.ip_address(), :inet.port_number(), :inet.port_number()) ::
          boolean()
  def local_endpoint?(ip, port, listen_port) do
    global_at_listen_port?(ip, port, listen_port) or reflexive_endpoint?(ip, port, listen_port)
  end

  # (any of our locally-known globals) at our listen port — the direct case:
  # a peer heard via tracker/DHT/PEX that advertises the exact address+port
  # we're listening on. Under CGNAT our listen port matches the mapped port
  # (UPnP maps 6881↔6881 on this host), so this catches most self-loops.
  #
  # IPv6: BEP-7 trackers often echo the announcer back into the peer list. Under
  # privacy extensions we may rotate host-ids within the same /64 — exact 128-bit
  # match misses those, but dialing same-/64 at our listen port is still a
  # self-loop (connect timeout → DialBackoff blocks the only "v6" candidates).
  defp global_at_listen_port?(ip, port, listen_port) do
    port == listen_port and global_ip_at_listen_port?(ip)
  end

  defp global_ip_at_listen_port?({a, b, c, d}) do
    Acceptor.all_global_ips().inet == {a, b, c, d}
  end

  defp global_ip_at_listen_port?({a, b, c, d, _, _, _, _}) do
    prefix = {a, b, c, d}

    Acceptor.all_global_ips().inet6_all
    |> Enum.any?(fn local ->
      case local do
        {la, lb, lc, ld, _, _, _, _} -> {la, lb, lc, ld} == prefix
        _ -> false
      end
    end)
  end

  defp global_ip_at_listen_port?(_), do: false

  # STUN reflexive (external NAT-mapped) endpoint: a peer whose (ip, port)
  # equals what we look like from the public internet is also us.
  #
  # Two shapes to catch:
  #   1. Exact match against a STUN reflexive `{ip, port}` — the UDP path.
  #   2. Reflexive IP paired with our listen_port — the TCP path under CGNAT.
  #      Trackers echo our announce (source_ip=CGNAT public, port=our
  #      announced listen port), so peers routinely re-learn us as
  #      {public_ip, listen_port}. STUN only observes the UDP mapped port
  #      (which differs from the TCP path), so we can't compare TCP ports
  #      exactly, but the (public_ip, listen_port) pair is a strong signal.
  defp reflexive_endpoint?(ip, port, listen_port) do
    reflexives = NAT.Stun.reflexives()

    {ip, port} in reflexives or
      (port == listen_port and Enum.any?(reflexives, fn {rip, _} -> rip == ip end))
  end

  # Skip IPv6 endpoints when this host has no usable global IPv6 — gen_tcp/utp dials
  # raise :badarg on macOS without IPv6 routing (peer_dial failed=%{badarg: N} spam).
  @spec ipv6_dialable?(:inet.ip_address()) :: boolean()
  def ipv6_dialable?({_, _, _, _}), do: true

  def ipv6_dialable?({_, _, _, _, _, _, _, _}) do
    Acceptor.primary_ips().inet6 != nil
  end

  def ipv6_dialable?(_), do: false

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
    timeout = if tuple_size(ip) == 8, do: @connect_timeout_v6_ms, else: @connect_timeout_ms

    case :gen_tcp.connect(ip, port, opts, timeout) do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        error
    end
  rescue
    ArgumentError -> {:error, :badarg}
  catch
    :error, :badarg -> {:error, :badarg}
    :exit, :badarg -> {:error, :badarg}
    :exit, {:badarg, _} -> {:error, :badarg}
  end

  @spec family_for_ip(:inet.ip_address()) :: :inet | :inet6
  defp family_for_ip({_, _, _, _}), do: :inet
  defp family_for_ip({_, _, _, _, _, _, _, _}), do: :inet6

  @spec do_recv(Peer.Transport.socket()) :: :ok
  defp do_recv(socket) do
    # Sniff the first byte: a plaintext BitTorrent handshake starts with the
    # pstrlen byte (19); anything else is the first byte of an MSE `Ya`.
    case Peer.Transport.recv(socket, 1, @handshake_recv_timeout_ms) do
      {:ok, @pstrlen} -> do_recv_plaintext(socket)
      {:ok, <<_first>> = prefix} -> do_recv_mse(socket, prefix)
      {:error, _} -> safe_close(socket)
    end
  end

  @spec do_recv_plaintext(Peer.Transport.socket()) :: :ok
  defp do_recv_plaintext(socket) do
    with {:ok, rest} <- Peer.Transport.recv(socket, @msg_length - 1, @handshake_recv_timeout_ms),
         {hash, peer_id, reserved} <- parse_handshake(<<@pstrlen::binary, rest::binary>>),
         false <- BlackList.member?(peer_id),
         true <- Torrent.has_hash?(hash),
         :ok <- send_msg(socket, hash),
         :ok <- add_peer(hash, peer_id, reserved, socket, peer_endpoint(nil, socket)) do
      :ok
    else
      _ -> safe_close(socket)
    end
  end

  # Inbound MSE: run the responder handshake (the peeked byte is the start of
  # Ya), recover the peer's BT handshake from the encrypted IA, and continue over
  # the cipher-wrapped socket.
  @spec do_recv_mse(Peer.Transport.socket(), binary()) :: :ok
  defp do_recv_mse(socket, prefix) do
    resolver = Handshake.resolver(Torrents.list())

    with {:ok, %{recv: r, send: s, leftover: ia}} <-
           Handshake.respond(socket, resolver, @handshake_recv_timeout_ms, prefix),
         mse_socket = Peer.Transport.wrap(socket, %{recv: r, send: s}),
         {hash, peer_id, reserved} <- parse_handshake(ia),
         false <- BlackList.member?(peer_id),
         true <- Torrent.has_hash?(hash),
         :ok <- send_msg(mse_socket, hash),
         :ok <- add_peer(hash, peer_id, reserved, mse_socket, peer_endpoint(nil, mse_socket)) do
      Logger.debug(
        "[mse] inbound_accepted hash=#{Torrent.hex_encoded_hash(hash)} peer=#{Peer.log_id(peer_id)}"
      )

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

  @spec start_peer_protocol(Peer.key()) :: :ok | {:error, term()}
  defp start_peer_protocol(key, attempts \\ 8)

  defp start_peer_protocol(_key, 0), do: {:error, :noproc}

  defp start_peer_protocol(key, attempts) when is_tuple(key) do
    Peer.Controller.start_protocol(key)
    :ok
  catch
    :exit, reason ->
      if retryable_start_protocol?(reason) and attempts > 1 do
        Process.sleep(25)
        start_peer_protocol(key, attempts - 1)
      else
        {:error, reason}
      end
  end

  defp retryable_start_protocol?(:noproc), do: true
  defp retryable_start_protocol?(:normal), do: true
  defp retryable_start_protocol?(:peer_not_registered), do: true
  defp retryable_start_protocol?({:noproc, _}), do: true
  defp retryable_start_protocol?({:normal, _}), do: true
  defp retryable_start_protocol?({:shutdown, _}), do: true
  defp retryable_start_protocol?(_), do: false

  defp add_peer(hash, peer_id, reserved, socket, endpoint_or_peer, origin \\ :inbound)

  defp add_peer(hash, peer_id, reserved, socket, %Peer{} = peer, origin) do
    add_peer(hash, peer_id, reserved, socket, peer_endpoint(peer, socket), origin)
  end

  defp add_peer(hash, peer_id, reserved, socket, endpoint, origin) do
    case Torrent.add_peer(hash, peer_id, reserved, socket) do
      {:ok, pid} ->
        handoff_socket(hash, pid, socket, endpoint, origin)

      {:ok, pid, _} ->
        handoff_socket(hash, pid, socket, endpoint, origin)

      {:error, :max_peers} ->
        safe_close(socket)
        {:error, :max_peers}

      _ ->
        safe_close(socket)
        {:error, :add_peer_failed}
    end
  end

  @spec handoff_socket(
          Torrent.hash(),
          pid(),
          Peer.Transport.socket(),
          term(),
          :inbound | :outbound
        ) ::
          :ok | {:error, term()}
  defp handoff_socket(hash, peer_supervisor, socket, endpoint, origin) do
    with sender when is_pid(sender) <- Peer.sender_pid(peer_supervisor),
         key when is_tuple(key) <- Peer.get_key(peer_supervisor),
         :ok <- register_endpoint(hash, endpoint, peer_supervisor),
         :ok <- transfer_controlling_process(socket, sender),
         :ok <- maybe_set_connection_origin(key, origin),
         :ok <- start_peer_protocol(key),
         :ok <- safe_activate(key) do
      Logger.debug(
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

  @spec maybe_set_connection_origin(Peer.key(), :inbound | :outbound) :: :ok
  defp maybe_set_connection_origin(key, :outbound),
    do: Peer.Controller.set_connection_origin(key, :outbound)

  defp maybe_set_connection_origin(_key, :inbound), do: :ok

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
    case Torrent.get(hash, :peer_status) do
      index when is_integer(index) -> Peer.interested(pid, index)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp send_msg(socket, hash) do
    case Peer.Transport.send(socket, handshake_bytes(hash)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec handshake_bytes(Torrent.hash()) :: binary()
  defp handshake_bytes(hash) do
    IO.iodata_to_binary([@pstrlen, @pstr, Peer.reserved(), hash, Peer.id()])
  end

  @spec recv_msg(Peer.Transport.socket()) ::
          {binary(), binary(), Peer.reserved()} | {:error, term()}
  defp recv_msg(socket) do
    case Peer.Transport.recv(socket, @msg_length, @handshake_recv_timeout_ms) do
      {:ok, bytes} -> parse_handshake(bytes)
      {:error, _} = error -> error
    end
  end

  @spec parse_handshake(binary()) ::
          {binary(), binary(), Peer.reserved()} | {:error, :invalid_handshake}
  defp parse_handshake(
         <<@pstrlen, @pstr, reserved::bytes-size(8), hash::bytes-size(20),
           peer_id::bytes-size(20)>>
       ) do
    {hash, peer_id, reserved}
  end

  defp parse_handshake(_), do: {:error, :invalid_handshake}

  @spec safe_close(Peer.Transport.socket()) :: :ok
  defp safe_close({:mse, _, _} = socket) do
    Peer.Transport.close(socket)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

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

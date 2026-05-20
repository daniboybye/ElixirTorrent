defmodule DHT do
  @moduledoc """
  BEP 5 DHT — UDP KRPC node for trackerless peer discovery.

  Public API:

    * `get_peers/2` — iterative get_peers lookup for an info hash
    * `announce/2` — announce our BitTorrent listen port to closest nodes
    * `seed_node/2` — ping a node learned from a BT PORT message (BEP 5 § extension)
    * `add_node/1` — seed routing table with a known contact
    * `port/0`, `enabled?/0` — runtime status

  DHT failures are isolated: callers receive `{:error, reason}` and downloads continue.
  """

  use GenServer

  alias DHT.{
    BEP42,
    Compact,
    Config,
    KRPC,
    Lookup,
    NodeId,
    PeerStore,
    RoutingStore,
    RoutingTable,
    RoutingTables,
    Token
  }

  require Logger

  @version Config.version_string()
  @token_rotate_ms 5 * 60 * 1_000
  @refresh_ms 15 * 60 * 1_000
  @persist_ms 5 * 60 * 1_000
  @bootstrap_after_ms 1_000
  @bootstrap_lookup_waits 12
  @bootstrap_lookup_wait_ms 500
  @min_routing_nodes 1
  @max_pending 256
  @max_announce_tokens 512
  @reannounce_interval_ms 15 * 60 * 1_000

  defstruct [
    :socket_v4,
    :socket_v6,
    :node_id,
    :port,
    routing_tables: nil,
    tokens: nil,
    peer_store: %{},
    pending: %{},
    lookups: %{},
    announce_tokens: %{},
    announce_timers: %{},
    bootstrapped?: false
  ]

  @type t :: %__MODULE__{}

  # --- Public API ---

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Config.enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?() and Process.whereis(__MODULE__) != nil

  @spec port() :: :inet.port_number() | nil
  def port do
    if enabled?(), do: GenServer.call(__MODULE__, :port, 5_000)
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec udp_socket(:inet | :inet6) :: port() | nil
  def udp_socket(family \\ :inet) do
    if enabled?(), do: GenServer.call(__MODULE__, {:udp_socket, family}, 5_000)
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec send_udp(:inet.ip_address(), :inet.port_number(), iodata()) :: :ok | {:error, term()}
  def send_udp(ip, port, data) do
    if enabled?() do
      GenServer.call(__MODULE__, {:send_udp, ip, port, data}, 5_000)
    else
      {:error, :disabled}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec get_peers(Torrent.hash(), keyword()) :: {:ok, [Peer.t()]} | {:error, term()}
  def get_peers(hash, opts \\ []) do
    if Config.enabled?() and byte_size(hash) == 20 do
      timeout = Keyword.get(opts, :timeout, Config.lookup_timeout_ms())

      GenServer.call(__MODULE__, {:get_peers, hash, timeout}, timeout + 1_000)
    else
      {:error, :disabled}
    end
  catch
    :exit, _ -> {:error, :timeout}
  end

  @spec announce(Torrent.hash(), :inet.port_number()) :: :ok
  def announce(hash, port) do
    if Config.enabled?() and byte_size(hash) == 20 and is_integer(port) do
      GenServer.cast(__MODULE__, {:announce, hash, port})
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec seed_node(:inet.ip_address(), :inet.port_number()) :: :ok
  def seed_node(ip, port) do
    if Config.enabled?() and is_integer(port) do
      GenServer.cast(__MODULE__, {:seed_node, ip, port})
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec add_node(Compact.contact()) :: :ok
  def add_node(%{id: id, ip: ip, port: port}) do
    if Config.enabled?() and byte_size(id) == 20 and is_integer(port) do
      GenServer.cast(__MODULE__, {:add_node, %{id: id, ip: ip, port: port}})
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  def add_node(_), do: :ok

  # --- GenServer ---

  @impl GenServer
  def init(_opts) do
    # Trap exits so the supervisor's shutdown signal runs terminate/2 (which
    # persists the routing table). A plain GenServer would be killed outright by
    # exit(:shutdown) without terminate ever firing.
    Process.flag(:trap_exit, true)
    node_id = NodeId.get()

    with {:ok, socket_v4, socket_v6, port} <- open_sockets(),
         :ok <- bind_socket(socket_v4),
         :ok <- maybe_bind_socket(socket_v6) do
      tables = RoutingStore.load(RoutingTables.new(node_id))
      tokens = Token.new()

      schedule_bootstrap()
      schedule_token_rotate(@token_rotate_ms)
      schedule_refresh(@refresh_ms)
      schedule_persist(@persist_ms)
      :ok = :inet.setopts(socket_v4, active: :once)
      if socket_v6, do: :inet.setopts(socket_v6, active: :once)

      %{inet: ip4, inet6: ip6} = Acceptor.primary_ips()

      Logger.info(
        "[dht] socket family=inet port=#{port} bind=#{if ip4, do: Acceptor.format_ip(ip4), else: "any"} want=#{inspect(dht_want())}"
      )

      if socket_v6 && ip6 do
        Logger.info(
          "[dht] socket family=inet6 port=#{port} bind=#{Acceptor.format_ip(ip6)} v6only=true"
        )
      end

      Logger.info(
        "[dht] listening port=#{port} ipv4=#{if ip4, do: Acceptor.format_ip(ip4), else: "none"} ipv6=#{if ip6, do: Acceptor.format_ip(ip6), else: "none"} routing_v4=#{RoutingTable.node_count(tables.v4)} routing_v6=#{RoutingTable.node_count(tables.v6)}"
      )

      {:ok,
       %__MODULE__{
         socket_v4: socket_v4,
         socket_v6: socket_v6,
         node_id: node_id,
         port: port,
         routing_tables: tables,
         tokens: tokens
       }}
    else
      {:error, reason} ->
        Logger.warning("DHT disabled: could not bind UDP port reason=#{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{routing_tables: tables}) when is_map(tables) do
    # Persist on clean shutdown so a quit-then-relaunch keeps the routing table.
    RoutingStore.save(tables)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl GenServer
  def handle_call(:port, _from, %__MODULE__{port: port} = state), do: {:reply, port, state}

  def handle_call({:udp_socket, family}, _from, state),
    do: {:reply, select_socket(state, family), state}

  def handle_call(:udp_socket, from, state),
    do: handle_call({:udp_socket, :inet}, from, state)

  def handle_call({:send_udp, ip, port, data}, _from, state) do
    socket = socket_for_dest(state, ip)
    {:reply, :gen_udp.send(socket, ip, port, data), state}
  end

  def handle_call({:get_peers, hash, timeout}, from, state) do
    ref = make_ref()
    {:noreply, start_lookup(state, hash, ref, from, timeout)}
  end

  @impl GenServer
  def handle_cast({:announce, hash, port}, state) do
    # Peer discovery casts this on every tracker/DHT round; BEP 5 wants one
    # announce per ~15 min. A live reannounce timer or in-flight announce
    # lookup means we are already covered — treat the cast as "ensure announced".
    if announce_pending?(state, hash) do
      {:noreply, state}
    else
      {:noreply, start_announce_lookup(state, hash, port)}
    end
  end

  def handle_cast({:add_node, contact}, state) do
    state = learn_remote_contact(state, contact)
    {:noreply, ping_node(state, contact)}
  end

  def handle_cast({:seed_node, ip, port}, state) do
    # BEP 5 § BitTorrent Protocol Extension — learn node id from ping response.
    contact = %{id: <<0::160>>, ip: ip, port: port}
    {:noreply, ping_node(state, contact)}
  end

  @impl GenServer
  def handle_info(:bootstrap, state) do
    {:noreply, bootstrap(state)}
  end

  def handle_info(:rotate_tokens, state) do
    schedule_token_rotate(@token_rotate_ms)
    {:noreply, %{state | tokens: Token.maybe_rotate(state.tokens)}}
  end

  def handle_info(:refresh_buckets, state) do
    schedule_refresh(@refresh_ms)
    {:noreply, refresh_stale_buckets(state)}
  end

  def handle_info(:persist_routing, state) do
    schedule_persist(@persist_ms)
    RoutingStore.save(state.routing_tables)
    {:noreply, state}
  end

  # With trap_exit on, a linked UDP socket dying arrives here (the parent
  # supervisor's shutdown exit is handled by gen_server → terminate/2, not this).
  # Abnormal socket death should still restart us (re-opening sockets), like
  # before; terminate/2 persists on the way out.
  def handle_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info({:udp, socket, ip, port, packet}, state)
      when socket == state.socket_v4 or socket == state.socket_v6 do
    :inet.setopts(socket, active: :once)
    {:noreply, handle_packet(state, socket, ip, port, packet)}
  end

  def handle_info({:udp, _socket, _ip, _port, _packet}, state), do: {:noreply, state}

  def handle_info({:udp_error, socket, reason}, state)
      when socket == state.socket_v4 or socket == state.socket_v6 do
    Logger.debug("DHT UDP error family=#{socket_family(state, socket)} reason=#{inspect(reason)}")

    {:noreply, state}
  end

  def handle_info({:query_timeout, tid}, state) do
    {pending, state} = pop_pending(state, tid)
    state = handle_query_failure(state, pending)
    state = maybe_lookup_step(state, pending)
    {:noreply, state}
  end

  def handle_info({:lookup_timeout, ref}, state) do
    case Map.get(state.lookups, ref) do
      nil ->
        {:noreply, state}

      %{purpose: :bootstrap} ->
        {:noreply, drop_lookup(state, ref)}

      %{purpose: :announce} = lookup ->
        {:noreply, finish_announce(state, ref, lookup)}

      %{from: from, peers: peers} when peers != [] ->
        GenServer.reply(from, {:ok, cap_lookup_peers(peers, Config.max_lookup_peers())})
        {:noreply, drop_lookup(state, ref)}

      %{from: from} ->
        GenServer.reply(from, {:error, :no_peers})
        {:noreply, drop_lookup(state, ref)}
    end
  end

  def handle_info({:reannounce, hash, port}, state) do
    state = %{state | announce_timers: Map.delete(state.announce_timers, hash)}
    {:noreply, start_announce_lookup(state, hash, port)}
  end

  def handle_info({:lookup_step, ref}, state) do
    {:noreply, continue_lookup(state, ref)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- UDP server (incoming KRPC) ---

  @spec handle_packet(t(), port(), :inet.ip_address(), :inet.port_number(), binary()) :: t()
  defp handle_packet(state, socket, ip, port, packet) do
    if UTP.Packet.utp_packet?(packet) do
      :ok = UTP.Dispatcher.dispatch(socket, ip, port, packet)
      state
    else
      handle_dht_packet(state, socket, ip, port, packet)
    end
  end

  @spec handle_dht_packet(t(), port(), :inet.ip_address(), :inet.port_number(), binary()) :: t()
  defp handle_dht_packet(state, socket, ip, port, packet) do
    case KRPC.decode(packet) do
      {:ok, {:query, query}} ->
        handle_query(state, ip, port, query, socket_family(state, socket))

      {:ok, {:response, response}} ->
        handle_response(state, ip, port, response)

      {:ok, {:error, _error}} ->
        state

      {:error, _} ->
        state
    end
  rescue
    exception ->
      # A single malformed packet must never take down the DHT server.
      Logger.warning(
        "[dht] packet_crash from=#{Acceptor.format_ip(ip)}:#{port} error=#{Exception.message(exception)}"
      )

      state
  end

  @spec handle_query(
          t(),
          :inet.ip_address(),
          :inet.port_number(),
          KRPC.query(),
          :inet | :inet6
        ) :: t()
  defp handle_query(state, ip, port, query, request_family) do
    contact = %{id: query.node_id, ip: ip, port: port}
    state = learn_remote_contact(state, contact, from_query: true)

    case query.method do
      {:unknown, _method} ->
        send_error(state, ip, port, query.transaction_id, 204, "Method Unknown")
        state

      method when method in [:ping, :find_node, :get_peers, :announce_peer] ->
        reply_known_query(state, ip, port, query, method, request_family)
    end
  end

  @spec reply_known_query(
          t(),
          :inet.ip_address(),
          :inet.port_number(),
          KRPC.query(),
          atom(),
          :inet | :inet6
        ) :: t()
  defp reply_known_query(state, ip, port, query, method, request_family) do
    if valid_query_args?(query) do
      dispatch_query_method(state, ip, port, query, method, request_family)
    else
      # BEP 5: queries with missing/invalid arguments get a 203 protocol error.
      send_error(state, ip, port, query.transaction_id, 203, "Protocol Error")
      state
    end
  end

  @spec dispatch_query_method(
          t(),
          :inet.ip_address(),
          :inet.port_number(),
          KRPC.query(),
          atom(),
          :inet | :inet6
        ) :: t()
  defp dispatch_query_method(state, ip, port, query, :ping, _family),
    do: reply_ping(state, ip, port, query.transaction_id)

  defp dispatch_query_method(state, ip, port, query, :find_node, family),
    do: reply_find_node(state, ip, port, query, family)

  defp dispatch_query_method(state, ip, port, query, :get_peers, family),
    do: reply_get_peers(state, ip, port, query, family)

  defp dispatch_query_method(state, ip, port, query, :announce_peer, _family),
    do: handle_announce_peer(state, ip, port, query)

  @spec valid_query_args?(KRPC.query()) :: boolean()
  defp valid_query_args?(%{method: :ping}), do: true

  defp valid_query_args?(%{method: :find_node} = q),
    do: node_id_arg?(Map.get(q, :target))

  defp valid_query_args?(%{method: :get_peers} = q),
    do: node_id_arg?(Map.get(q, :info_hash))

  defp valid_query_args?(%{method: :announce_peer} = q) do
    node_id_arg?(Map.get(q, :info_hash)) and is_binary(Map.get(q, :token)) and
      (Map.get(q, :implied_port) == 1 or is_integer(Map.get(q, :port)))
  end

  defp node_id_arg?(value), do: is_binary(value) and byte_size(value) == 20

  @spec reply_ping(t(), :inet.ip_address(), :inet.port_number(), binary()) :: t()
  defp reply_ping(state, ip, port, tid) do
    response = %{transaction_id: tid, node_id: state.node_id, version: @version}
    send_response(state, ip, port, response)
    state
  end

  @spec reply_find_node(
          t(),
          :inet.ip_address(),
          :inet.port_number(),
          KRPC.query(),
          :inet | :inet6
        ) :: t()
  defp reply_find_node(
         state,
         ip,
         port,
         %{transaction_id: tid, target: target} = query,
         request_family
       ) do
    want = Map.get(query, :want)
    node_fields = reply_node_fields(state.routing_tables, target, want, request_family)

    response =
      Map.merge(
        %{
          transaction_id: tid,
          node_id: state.node_id,
          version: @version
        },
        node_fields
      )

    send_response(state, ip, port, response)
    state
  end

  @spec reply_get_peers(
          t(),
          :inet.ip_address(),
          :inet.port_number(),
          KRPC.query(),
          :inet | :inet6
        ) :: t()
  defp reply_get_peers(
         state,
         ip,
         port,
         %{transaction_id: tid, info_hash: hash} = query,
         request_family
       ) do
    token = Token.issue_for_node(state.tokens, query.node_id, ip)

    peers =
      state.peer_store
      |> PeerStore.get(hash)
      |> Enum.filter(&peer_in_family?(&1, request_family))

    want = Map.get(query, :want)

    response =
      if peers == [] do
        node_fields = reply_node_fields(state.routing_tables, hash, want, request_family)

        %{
          transaction_id: tid,
          node_id: state.node_id,
          version: @version
        }
        |> maybe_put_token(token)
        |> Map.merge(node_fields)
      else
        values =
          peers
          |> Enum.map(&peer_to_compact_value/1)
          |> Enum.reject(&is_nil/1)

        %{
          transaction_id: tid,
          node_id: state.node_id,
          values: values,
          version: @version
        }
        |> maybe_put_token(token)
      end

    send_response(state, ip, port, response)
    state
  end

  @spec peer_to_compact_value(Peer.t()) :: binary() | nil
  defp peer_to_compact_value(%Peer{ip: {a, b, c, d}, port: peer_port}) do
    case Compact.encode_peer({a, b, c, d}, peer_port) do
      blob when is_binary(blob) -> blob
      _ -> nil
    end
  end

  defp peer_to_compact_value(%Peer{ip: {s1, s2, s3, s4, s5, s6, s7, s8}, port: peer_port}) do
    case Compact.encode_ipv6_peer({s1, s2, s3, s4, s5, s6, s7, s8}, peer_port) do
      blob when is_binary(blob) -> blob
      _ -> nil
    end
  end

  defp peer_to_compact_value(_), do: nil

  @spec handle_announce_peer(t(), :inet.ip_address(), :inet.port_number(), KRPC.query()) :: t()
  defp handle_announce_peer(state, ip, port, query) do
    valid? =
      Token.valid?(state.tokens, ip, query.token) and byte_size(query.info_hash) == 20

    peer_port =
      case Map.get(query, :implied_port) do
        1 -> port
        _ -> query.port
      end

    cond do
      not valid? ->
        send_error(state, ip, port, query.transaction_id, 203, "invalid token or arguments")
        state

      not is_integer(peer_port) or peer_port not in 1..65_535 ->
        send_error(state, ip, port, query.transaction_id, 203, "invalid token or arguments")
        state

      true ->
        peer = %Peer{ip: ip, port: peer_port}
        store = PeerStore.put(state.peer_store, query.info_hash, peer)

        response = %{
          transaction_id: query.transaction_id,
          node_id: state.node_id,
          version: @version
        }

        send_response(state, ip, port, response)
        %{state | peer_store: store}
    end
  end

  @spec handle_response(t(), :inet.ip_address(), :inet.port_number(), KRPC.response()) :: t()
  defp handle_response(state, ip, port, response) do
    tid = response.transaction_id

    case pop_pending_response(state, tid, ip, port) do
      {nil, state} ->
        state

      {pending, state} ->
        Process.cancel_timer(pending.timer_ref)

        contact = %{id: response.node_id, ip: ip, port: port}

        if BEP42.valid_or_exempt?(response.node_id, ip) do
          apply_trusted_response(state, pending, ip, port, response, contact)
        else
          reject_untrusted_response(state, pending, ip, response)
        end
    end
  end

  @spec apply_trusted_response(
          t(),
          map(),
          :inet.ip_address(),
          :inet.port_number(),
          KRPC.response(),
          Compact.contact()
        ) :: t()
  defp apply_trusted_response(state, pending, ip, port, response, contact) do
    state = learn_remote_contact(state, contact)

    tables = RoutingTables.mark_good(state.routing_tables, contact, from_query: true)
    state = %{state | routing_tables: tables}
    peers = KRPC.response_peers(response)

    nodes =
      response
      |> KRPC.response_nodes()
      |> compliant_contacts()

    maybe_log_ipv6_peers(peers)

    state =
      if response.token do
        state
        |> put_announce_token({ip, port}, response.token)
        |> record_lookup_announce_token(pending, ip, port, response.token)
      else
        state
      end

    state = merge_discovered_nodes(state, nodes)
    dispatch_pending(state, pending, peers, nodes)
  end

  @spec reject_untrusted_response(t(), map(), :inet.ip_address(), KRPC.response()) :: t()
  defp reject_untrusted_response(state, pending, ip, response) do
    nodes =
      response
      |> KRPC.response_nodes()
      |> compliant_contacts()

    state =
      state
      |> mark_pending_bad(pending, ip)
      |> merge_discovered_nodes(nodes)

    maybe_lookup_step(state, pending)
  end

  @spec maybe_log_ipv6_peers([Peer.t()]) :: :ok
  defp maybe_log_ipv6_peers(peers) do
    if peers != [] do
      v6 = Enum.count(peers, &(tuple_size(&1.ip) == 8))

      if v6 > 0 do
        Logger.debug("[dht] get_peers ipv6_peers=#{v6} total=#{length(peers)}")
      end
    end

    :ok
  end

  # --- Outgoing queries ---

  @spec send_query(t(), Compact.contact() | RoutingTable.entry(), atom(), keyword()) ::
          {:ok, binary(), t()} | {:error, :too_many_pending, t()}
  defp send_query(state, node, method, args \\ [], opts \\ []) do
    tid = transaction_id()
    query = build_query(method, tid, state.node_id, args)

    pending_meta =
      Keyword.get(opts, :pending, %{type: :query, node: node, method: method})

    case register_pending(state, tid, pending_meta) do
      {:error, :too_many_pending, new_state} ->
        {:error, :too_many_pending, new_state}

      {:ok, new_state} ->
        socket = socket_for_dest(new_state, node.ip)
        packet = KRPC.encode_query(query)
        _ = :gen_udp.send(socket, node.ip, node.port, packet)
        {:ok, tid, new_state}
    end
  end

  @spec build_query(atom(), binary(), RoutingTable.node_id(), keyword()) :: KRPC.query()
  defp build_query(:ping, tid, node_id, _),
    do: %{method: :ping, transaction_id: tid, node_id: node_id, version: @version}

  defp build_query(:find_node, tid, node_id, args) do
    query = %{
      method: :find_node,
      transaction_id: tid,
      node_id: node_id,
      target: Keyword.fetch!(args, :target),
      version: @version
    }

    maybe_put_query_want(query, args)
  end

  defp build_query(:get_peers, tid, node_id, args) do
    query = %{
      method: :get_peers,
      transaction_id: tid,
      node_id: node_id,
      info_hash: Keyword.fetch!(args, :info_hash),
      version: @version
    }

    maybe_put_query_want(query, args)
  end

  defp build_query(:announce_peer, tid, node_id, args),
    do: %{
      method: :announce_peer,
      transaction_id: tid,
      node_id: node_id,
      info_hash: Keyword.fetch!(args, :info_hash),
      port: Keyword.fetch!(args, :port),
      token: Keyword.fetch!(args, :token),
      implied_port: Keyword.get(args, :implied_port, 0),
      version: @version
    }

  @spec ping_node(t(), Compact.contact()) :: t()
  defp ping_node(state, node) do
    case send_query(state, node, :ping) do
      {:ok, _tid, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  # --- Bootstrap (BEP 5 § bootstrap) ---

  @spec bootstrap(t()) :: t()
  defp bootstrap(%__MODULE__{bootstrapped?: true} = state), do: state

  defp bootstrap(state) do
    ref = make_ref()

    lookup = %{
      ref: ref,
      purpose: :bootstrap,
      hash: state.node_id,
      shortlist: Lookup.initial_shortlist(state.routing_tables, state.node_id),
      peers: [],
      queried: MapSet.new(),
      timer_ref: Process.send_after(self(), {:lookup_timeout, ref}, Config.lookup_timeout_ms())
    }

    state = %{state | lookups: Map.put(state.lookups, ref, lookup), bootstrapped?: true}

    state =
      Enum.reduce(Config.bootstrap_routers(), state, fn {host, port}, acc ->
        Enum.reduce(resolve_bootstrap_hosts(host), acc, fn ip, inner ->
          bootstrap_ip(inner, ip, port, ref)
        end)
      end)

    schedule_lookup_step(state, ref, 0)
  end

  @spec resolve_bootstrap_hosts(String.t()) :: [:inet.ip_address()]
  defp resolve_bootstrap_hosts(host) do
    char_host = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(char_host, :inet) do
        {:ok, ips} -> ips
        {:error, _} -> []
      end

    v6 =
      case :inet.getaddrs(char_host, :inet6) do
        {:ok, ips} -> ips
        {:error, _} -> []
      end

    v4 ++ v6
  end

  @spec bootstrap_ip(t(), :inet.ip_address(), :inet.port_number(), reference()) :: t()
  defp bootstrap_ip(state, ip, port, lookup_ref) do
    bootstrap_id = :crypto.strong_rand_bytes(20)
    contact = %{id: bootstrap_id, ip: ip, port: port}
    pending = %{type: :bootstrap, lookup_ref: lookup_ref, node: contact}

    case send_query(state, contact, :find_node, [target: state.node_id], pending: pending) do
      {:ok, _tid, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  @spec refresh_stale_buckets(t()) :: t()
  defp refresh_stale_buckets(state) do
    state.routing_tables
    |> RoutingTables.stale_buckets()
    |> Enum.reduce(state, &refresh_one_stale_bucket/2)
  end

  @spec refresh_one_stale_bucket(RoutingTable.bucket(), t()) :: t()
  defp refresh_one_stale_bucket(bucket, acc) do
    target = RoutingTable.random_id_in_bucket(bucket)

    case RoutingTables.closest(acc.routing_tables, target, 1) do
      [node | _] -> send_find_node_refresh(acc, node, target)
      [] -> acc
    end
  end

  @spec send_find_node_refresh(t(), RoutingTable.entry(), RoutingTable.node_id()) :: t()
  defp send_find_node_refresh(acc, node, target) do
    case send_query(acc, node, :find_node, target: target) do
      {:ok, _tid, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  # --- get_peers lookup (BEP 5 § Peer lookup) ---

  @spec start_lookup(t(), Torrent.hash(), reference(), GenServer.from(), pos_integer()) :: t()
  defp start_lookup(state, hash, ref, from, timeout) do
    shortlist = Lookup.initial_shortlist(state.routing_tables, hash)

    lookup = %{
      ref: ref,
      purpose: :peer_lookup,
      from: from,
      hash: hash,
      shortlist: shortlist,
      peers: [],
      announce_nodes: %{},
      queried: MapSet.new(),
      bootstrap_waits: 0,
      timer_ref: Process.send_after(self(), {:lookup_timeout, ref}, timeout)
    }

    state = %{state | lookups: Map.put(state.lookups, ref, lookup)}
    schedule_lookup_step(state, ref, bootstrap_delay_ms(state))
  end

  @spec start_announce_lookup(t(), Torrent.hash(), :inet.port_number()) :: t()
  defp start_announce_lookup(state, hash, bt_port) do
    state = cancel_announce_timer(state, hash)
    ref = make_ref()
    shortlist = Lookup.initial_shortlist(state.routing_tables, hash)
    timeout = Config.lookup_timeout_ms()

    lookup = %{
      ref: ref,
      purpose: :announce,
      from: nil,
      hash: hash,
      bt_port: bt_port,
      shortlist: shortlist,
      peers: [],
      announce_nodes: %{},
      queried: MapSet.new(),
      bootstrap_waits: 0,
      timer_ref: Process.send_after(self(), {:lookup_timeout, ref}, timeout)
    }

    state = %{state | lookups: Map.put(state.lookups, ref, lookup)}
    schedule_lookup_step(state, ref, bootstrap_delay_ms(state))
  end

  # BEP 5 § bootstrap — defer the first lookup iteration until routers have responded.
  @spec bootstrap_delay_ms(t()) :: non_neg_integer()
  defp bootstrap_delay_ms(%__MODULE__{bootstrapped?: false}), do: @bootstrap_after_ms + 500

  defp bootstrap_delay_ms(%__MODULE__{routing_tables: tables}) do
    if RoutingTables.node_count(tables) >= @min_routing_nodes,
      do: 0,
      else: @bootstrap_lookup_wait_ms
  end

  @spec schedule_lookup_step(t(), reference(), non_neg_integer()) :: t()
  defp schedule_lookup_step(state, ref, 0) do
    Process.send(self(), {:lookup_step, ref}, [])
    state
  end

  defp schedule_lookup_step(state, ref, delay_ms) do
    Process.send_after(self(), {:lookup_step, ref}, delay_ms)
    state
  end

  @spec continue_lookup(t(), reference()) :: t()
  defp continue_lookup(state, ref) do
    case Map.get(state.lookups, ref) do
      nil ->
        state

      %{purpose: :bootstrap} = lookup ->
        continue_bootstrap_lookup(state, ref, lookup)

      %{hash: hash, shortlist: shortlist, peers: peers} = lookup ->
        continue_peer_lookup(state, ref, hash, lookup, shortlist, peers)

      _ ->
        state
    end
  end

  @spec continue_peer_lookup(t(), reference(), Torrent.hash(), map(), list(), [Peer.t()]) :: t()
  defp continue_peer_lookup(state, ref, hash, lookup, shortlist, peers) do
    shortlist = Lookup.refresh_shortlist(state.routing_tables, hash, shortlist)

    cond do
      peers != [] and Lookup.converged?(shortlist) ->
        finish_lookup_by_purpose(state, ref, lookup, peers)

      Lookup.converged?(shortlist) and peers == [] ->
        maybe_wait_for_bootstrap(state, ref, lookup, hash)

      true ->
        continue_peer_lookup_queries(state, ref, hash, lookup, shortlist, peers)
    end
  end

  @spec continue_peer_lookup_queries(
          t(),
          reference(),
          Torrent.hash(),
          map(),
          list(),
          [Peer.t()]
        ) :: t()
  defp continue_peer_lookup_queries(state, ref, hash, lookup, shortlist, peers) do
    {shortlist, query_ids} = Lookup.next_queries(shortlist)

    cond do
      query_ids == [] and peers == [] ->
        maybe_wait_for_bootstrap(state, ref, lookup, hash)

      query_ids == [] ->
        finish_lookup_by_purpose(state, ref, lookup, peers)

      true ->
        query_nodes_for_lookup(state, ref, hash, shortlist, query_ids, lookup, peers)
    end
  end

  @spec continue_bootstrap_lookup(t(), reference(), map()) :: t()
  defp continue_bootstrap_lookup(state, ref, lookup) do
    target = state.node_id
    shortlist = Lookup.refresh_shortlist(state.routing_tables, target, lookup.shortlist)

    cond do
      Lookup.converged?(shortlist) and pending_for_lookup?(state, ref) ->
        state

      Lookup.converged?(shortlist) ->
        drop_lookup(state, ref)

      true ->
        {shortlist, query_ids} = Lookup.next_queries(shortlist)
        query_nodes_for_lookup(state, ref, target, shortlist, query_ids, lookup, [])
    end
  end

  # Defer lookup while bootstrap fills the routing table (BEP 5 § bootstrap before search).
  @spec maybe_wait_for_bootstrap(t(), reference(), map(), Torrent.hash()) :: t()
  defp maybe_wait_for_bootstrap(state, ref, lookup, hash) do
    waits = Map.get(lookup, :bootstrap_waits, 0)
    node_count = RoutingTables.node_count(state.routing_tables)

    if waits < @bootstrap_lookup_waits and node_count < 8 do
      state = if state.bootstrapped?, do: state, else: bootstrap(state)

      updated =
        lookup
        |> Map.put(:shortlist, Lookup.initial_shortlist(state.routing_tables, hash))
        |> Map.put(:bootstrap_waits, waits + 1)

      state
      |> Map.put(:lookups, Map.put(state.lookups, ref, updated))
      |> schedule_lookup_step(ref, @bootstrap_lookup_wait_ms)
    else
      case Map.get(lookup, :purpose, :peer_lookup) do
        :announce ->
          finish_announce(state, ref, lookup)

        _ ->
          GenServer.reply(lookup.from, {:error, :no_peers})
          drop_lookup(state, ref)
      end
    end
  end

  @spec finish_lookup_by_purpose(t(), reference(), map(), [Peer.t()]) :: t()
  defp finish_lookup_by_purpose(state, ref, lookup, peers) do
    case Map.get(lookup, :purpose, :peer_lookup) do
      :announce -> finish_announce(state, ref, lookup)
      _ -> finish_lookup(state, ref, peers)
    end
  end

  @spec query_nodes_for_lookup(
          t(),
          reference(),
          Torrent.hash(),
          list(),
          list(),
          map(),
          [Peer.t()]
        ) :: t()
  defp query_nodes_for_lookup(state, ref, hash, shortlist, query_ids, lookup, peers) do
    {state, queried} =
      Enum.reduce(query_ids, {state, lookup.queried}, fn id, {acc, q} ->
        query_one_lookup_node(acc, ref, hash, lookup, id, q)
      end)

    updated =
      lookup
      |> Map.put(:shortlist, shortlist)
      |> Map.put(:peers, peers)
      |> Map.put(:queried, queried)

    %{state | lookups: Map.put(state.lookups, ref, updated)}
  end

  @spec query_one_lookup_node(t(), reference(), Torrent.hash(), map(), term(), MapSet.t()) ::
          {t(), MapSet.t()}
  defp query_one_lookup_node(acc, ref, hash, lookup, id, q) do
    case RoutingTables.find_entry(acc.routing_tables, id) do
      nil ->
        {acc, MapSet.put(q, id)}

      entry ->
        {method, args, pending_type} = lookup_query_spec(lookup, hash)
        pending = %{type: pending_type, lookup_ref: ref, node_id: id, node: entry}
        send_lookup_query(acc, entry, method, args, pending, id, q)
    end
  end

  @spec lookup_query_spec(map(), Torrent.hash()) :: {atom(), keyword(), atom()}
  defp lookup_query_spec(%{purpose: :bootstrap}, hash),
    do: {:find_node, [target: hash], :bootstrap_lookup}

  defp lookup_query_spec(_lookup, hash),
    do: {:get_peers, get_peers_args(hash), :lookup}

  @spec send_lookup_query(t(), RoutingTable.entry(), atom(), keyword(), map(), term(), MapSet.t()) ::
          {t(), MapSet.t()}
  defp send_lookup_query(acc, entry, method, args, pending, id, q) do
    case send_query(acc, entry, method, args, pending: pending) do
      {:ok, _tid, new_state} -> {new_state, MapSet.put(q, id)}
      {:error, _, new_state} -> {new_state, MapSet.put(q, id)}
    end
  end

  @spec finish_lookup(t(), reference(), [Peer.t()]) :: t()
  defp finish_lookup(state, ref, peers) do
    lookup = Map.get(state.lookups, ref)
    peers = cap_lookup_peers(peers, Config.max_lookup_peers())
    GenServer.reply(lookup.from, {:ok, peers})
    drop_lookup(state, ref)
  end

  @spec drop_lookup(t(), reference()) :: t()
  defp drop_lookup(state, ref) do
    case Map.get(state.lookups, ref) do
      %{timer_ref: timer_ref} -> Process.cancel_timer(timer_ref)
      _ -> :ok
    end

    %{state | lookups: Map.delete(state.lookups, ref)}
  end

  @spec dispatch_pending(t(), map(), [Peer.t()], [Compact.contact()]) :: t()
  defp dispatch_pending(state, %{lookup_ref: ref}, peers, nodes) do
    case Map.get(state.lookups, ref) do
      nil ->
        state

      lookup ->
        merged = Lookup.merge_nodes(lookup.shortlist, nodes, lookup.hash)

        peers =
          (lookup.peers ++ peers)
          |> Enum.uniq_by(&{&1.ip, &1.port})
          |> cap_lookup_peers(Config.max_lookup_peers())

        updated =
          lookup
          |> Map.put(:shortlist, merged)
          |> Map.put(:peers, peers)

        state = %{state | lookups: Map.put(state.lookups, ref, updated)}
        Process.send(self(), {:lookup_step, ref}, [])
        state
    end
  end

  defp dispatch_pending(state, _pending, _peers, _nodes), do: state

  @doc false
  @spec cap_lookup_peers([Peer.t()], pos_integer()) :: [Peer.t()]
  def cap_lookup_peers(peers, max) when is_list(peers) and is_integer(max) and max > 0 do
    {v6, v4} = Enum.split_with(peers, fn %Peer{ip: ip} -> tuple_size(ip) == 8 end)

    if v6 == [] do
      Enum.take(peers, max)
    else
      v6_slots = min(div(max, 2), length(v6))
      v6_take = Enum.take(v6, v6_slots)
      v4_take = Enum.take(v4, max - length(v6_take))
      v6_take ++ v4_take
    end
  end

  # --- announce_peer client (BEP 5 § announce after get_peers tokens) ---

  @spec finish_announce(t(), reference(), map()) :: t()
  defp finish_announce(state, ref, lookup) do
    hash = lookup.hash
    bt_port = lookup.bt_port
    node_count = map_size(lookup.announce_nodes)

    Logger.debug(
      "[dht_announce] hash=#{Torrent.hex_encoded_hash(hash)} port=#{bt_port} nodes=#{node_count}"
    )

    state =
      lookup.announce_nodes
      |> Enum.sort_by(fn {{ip, _port}, _token} -> contact_family_rank(ip) end)
      |> Enum.reduce(state, fn {{ip, port}, token}, acc ->
        node = %{id: <<0::160>>, ip: ip, port: port}

        case send_query(acc, node, :announce_peer,
               info_hash: hash,
               port: bt_port,
               token: token,
               implied_port: 1
             ) do
          {:ok, _tid, new_state} -> new_state
          {:error, _, new_state} -> new_state
        end
      end)

    state = drop_lookup(state, ref)
    schedule_reannounce(state, hash, bt_port)
  end

  @spec schedule_reannounce(t(), Torrent.hash(), :inet.port_number()) :: t()
  defp schedule_reannounce(state, hash, port) do
    timer = Process.send_after(self(), {:reannounce, hash, port}, @reannounce_interval_ms)
    %{state | announce_timers: Map.put(state.announce_timers, hash, timer)}
  end

  @spec announce_pending?(t(), Torrent.hash()) :: boolean()
  defp announce_pending?(state, hash) do
    Map.has_key?(state.announce_timers, hash) or
      Enum.any?(state.lookups, fn {_ref, lookup} ->
        Map.get(lookup, :purpose) == :announce and lookup.hash == hash
      end)
  end

  @spec cancel_announce_timer(t(), Torrent.hash()) :: t()
  defp cancel_announce_timer(state, hash) do
    case Map.get(state.announce_timers, hash) do
      nil ->
        state

      timer when is_reference(timer) ->
        Process.cancel_timer(timer)
        %{state | announce_timers: Map.delete(state.announce_timers, hash)}
    end
  end

  @spec record_lookup_announce_token(
          t(),
          map() | nil,
          :inet.ip_address(),
          :inet.port_number(),
          binary()
        ) ::
          t()
  defp record_lookup_announce_token(state, pending, ip, port, token) do
    case pending do
      %{lookup_ref: ref} when is_reference(ref) ->
        case Map.get(state.lookups, ref) do
          %{purpose: :announce} = lookup ->
            nodes = Map.put(lookup.announce_nodes, {ip, port}, token)
            updated = Map.put(lookup, :announce_nodes, nodes)
            %{state | lookups: Map.put(state.lookups, ref, updated)}

          _ ->
            state
        end

      _ ->
        state
    end
  end

  @spec put_announce_token(t(), {term(), term()}, binary()) :: t()
  defp put_announce_token(state, key, token) do
    tokens =
      state.announce_tokens
      |> Map.put(key, token)
      |> trim_map(@max_announce_tokens)

    %{state | announce_tokens: tokens}
  end

  # --- helpers ---

  @spec learn_remote_contact(t(), Compact.contact(), keyword()) :: t()
  defp learn_remote_contact(state, contact, opts \\ []) do
    if BEP42.valid_or_exempt?(contact.id, contact.ip) do
      insert_or_probe_replacement(state, contact, opts)
    else
      state
    end
  end

  @spec insert_or_probe_replacement(t(), Compact.contact(), keyword()) :: t()
  defp insert_or_probe_replacement(state, contact, opts) do
    case RoutingTables.replacement_probe(state.routing_tables, contact, opts) do
      nil ->
        %{state | routing_tables: RoutingTables.insert(state.routing_tables, contact, opts)}

      incumbent ->
        maybe_ping_replacement(state, incumbent, contact, opts)
    end
  end

  @spec maybe_ping_replacement(t(), RoutingTable.entry(), Compact.contact(), keyword()) :: t()
  defp maybe_ping_replacement(state, incumbent, contact, opts) do
    if replacement_probe_pending?(state, incumbent) do
      state
    else
      start_replacement_ping(state, incumbent, contact, opts)
    end
  end

  @spec start_replacement_ping(t(), RoutingTable.entry(), Compact.contact(), keyword()) :: t()
  defp start_replacement_ping(state, incumbent, contact, opts) do
    pending = %{
      type: :replacement_ping,
      node: incumbent,
      candidate: contact,
      candidate_opts: opts,
      attempts: 1
    }

    case send_query(state, incumbent, :ping, [], pending: pending) do
      {:ok, _tid, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  @spec replacement_probe_pending?(t(), RoutingTable.entry()) :: boolean()
  defp replacement_probe_pending?(state, incumbent) do
    Enum.any?(state.pending, fn
      {_tid, %{type: :replacement_ping, node: %{id: id, ip: ip}}} ->
        id == incumbent.id and ip == incumbent.ip

      _ ->
        false
    end)
  end

  @spec compliant_contacts([Compact.contact()]) :: [Compact.contact()]
  defp compliant_contacts(contacts) do
    Enum.filter(contacts, &BEP42.valid_or_exempt?(&1.id, &1.ip))
  end

  @spec merge_discovered_nodes(t(), [Compact.contact()]) :: t()
  defp merge_discovered_nodes(state, nodes) do
    nodes
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(state, fn node, acc ->
      learn_remote_contact(acc, node)
    end)
  end

  @spec send_response(t(), :inet.ip_address(), :inet.port_number(), KRPC.response()) :: :ok
  defp send_response(state, ip, port, response) do
    socket = socket_for_dest(state, ip)
    response = Map.put(response, :ip, compact_endpoint(ip, port))
    _ = :gen_udp.send(socket, ip, port, KRPC.encode_response(response))
    :ok
  end

  @spec send_error(t(), :inet.ip_address(), :inet.port_number(), binary(), 201..204, String.t()) ::
          :ok
  defp send_error(state, ip, port, tid, code, message) do
    socket = socket_for_dest(state, ip)

    packet =
      KRPC.encode_error(%{
        transaction_id: tid,
        code: code,
        message: message,
        ip: compact_endpoint(ip, port)
      })

    _ = :gen_udp.send(socket, ip, port, packet)
    :ok
  end

  @spec register_pending(t(), binary(), map()) ::
          {:ok, t()} | {:error, :too_many_pending, t()}
  defp register_pending(%__MODULE__{pending: pending} = state, tid, pending_meta) do
    if map_size(pending) >= @max_pending do
      {:error, :too_many_pending, state}
    else
      timer_ref = Process.send_after(self(), {:query_timeout, tid}, Config.query_timeout_ms())

      entry = Map.put(pending_meta, :timer_ref, timer_ref)

      {:ok, %{state | pending: Map.put(pending, tid, entry)}}
    end
  end

  @spec pop_pending(t(), binary()) :: {map() | nil, t()}
  defp pop_pending(state, tid) do
    case Map.pop(state.pending, tid) do
      {nil, pending} -> {nil, %{state | pending: pending}}
      {entry, pending} -> {entry, %{state | pending: pending}}
    end
  end

  @spec pop_pending_response(
          t(),
          binary(),
          :inet.ip_address(),
          :inet.port_number()
        ) :: {map() | nil, t()}
  defp pop_pending_response(state, tid, ip, port) do
    case Map.get(state.pending, tid) do
      %{node: %{ip: ^ip, port: ^port}} -> pop_pending(state, tid)
      _ -> {nil, state}
    end
  end

  @spec handle_query_failure(t(), map() | nil) :: t()
  defp handle_query_failure(
         state,
         %{type: :replacement_ping, attempts: 1, node: incumbent} = pending
       ) do
    tables = RoutingTables.mark_query_failed(state.routing_tables, incumbent)
    state = %{state | routing_tables: tables}
    retry = %{pending | attempts: 2}

    case send_query(state, incumbent, :ping, [], pending: retry) do
      {:ok, _tid, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  defp handle_query_failure(
         state,
         %{
           type: :replacement_ping,
           node: incumbent,
           candidate: candidate,
           candidate_opts: opts
         }
       ) do
    tables = RoutingTables.mark_query_failed(state.routing_tables, incumbent)
    state = %{state | routing_tables: tables}
    learn_remote_contact(state, candidate, opts)
  end

  defp handle_query_failure(state, %{node: %{id: id} = contact})
       when is_binary(id) and byte_size(id) == 20 do
    %{state | routing_tables: RoutingTables.mark_query_failed(state.routing_tables, contact)}
  end

  defp handle_query_failure(state, %{node_id: id}) when is_binary(id) and byte_size(id) == 20 do
    %{state | routing_tables: RoutingTables.mark_query_failed(state.routing_tables, id)}
  end

  defp handle_query_failure(state, _), do: state

  @spec mark_pending_bad(t(), map(), :inet.ip_address()) :: t()
  defp mark_pending_bad(state, %{node: %{id: id, ip: _ip} = contact}, _source_ip)
       when is_binary(id) and byte_size(id) == 20 do
    %{state | routing_tables: RoutingTables.mark_bad(state.routing_tables, contact)}
  end

  defp mark_pending_bad(state, pending, ip) do
    id =
      case pending do
        %{node: %{id: node_id}} -> node_id
        %{node_id: node_id} -> node_id
        _ -> nil
      end

    if is_binary(id) and byte_size(id) == 20 do
      contact = %{id: id, ip: ip, port: 0}
      %{state | routing_tables: RoutingTables.mark_bad(state.routing_tables, contact)}
    else
      state
    end
  end

  @spec maybe_lookup_step(t(), map() | nil) :: t()
  defp maybe_lookup_step(state, %{lookup_ref: ref}) do
    Process.send(self(), {:lookup_step, ref}, [])
    state
  end

  defp maybe_lookup_step(state, _), do: state

  @spec pending_for_lookup?(t(), reference()) :: boolean()
  defp pending_for_lookup?(state, ref) do
    Enum.any?(state.pending, fn
      {_tid, %{lookup_ref: ^ref}} -> true
      _ -> false
    end)
  end

  @spec transaction_id() :: binary()
  defp transaction_id, do: :crypto.strong_rand_bytes(2)

  @spec open_sockets() :: {:ok, port(), port() | nil, :inet.port_number()} | {:error, term()}
  defp open_sockets do
    case Config.port() do
      nil -> open_sockets_auto_port()
      port -> open_sockets_on_port(port)
    end
  end

  @spec open_sockets_auto_port() ::
          {:ok, port(), port() | nil, :inet.port_number()} | {:error, term()}
  defp open_sockets_auto_port do
    Enum.find_value(Acceptor.port_range(), {:error, :no_udp_port}, fn number ->
      case open_sockets_on_port(number) do
        {:ok, _, _, _} = ok -> ok
        {:error, _} -> nil
      end
    end)
  end

  @spec open_sockets_on_port(:inet.port_number()) ::
          {:ok, port(), port() | nil, :inet.port_number()} | {:error, term()}
  defp open_sockets_on_port(port) do
    with {:ok, socket_v4} <- open_v4_socket(port),
         {:ok, socket_v6} <- open_v6_socket(port) do
      {:ok, socket_v4, socket_v6, port}
    end
  end

  @spec open_v4_socket(:inet.port_number()) :: {:ok, port()} | {:error, term()}
  defp open_v4_socket(port) do
    opts = [:binary, :inet, active: false, reuseaddr: true, reuseport: true]
    :gen_udp.open(port, opts)
  end

  @spec open_v6_socket(:inet.port_number()) :: {:ok, port() | nil} | {:error, term()}
  defp open_v6_socket(port) do
    case Acceptor.primary_ips().inet6 do
      nil ->
        {:ok, nil}

      v6_addr ->
        opts = [
          :binary,
          :inet6,
          {:ipv6_v6only, true},
          {:ip, v6_addr},
          active: false,
          reuseaddr: true,
          reuseport: true
        ]

        case :gen_udp.open(port, opts) do
          {:ok, socket} ->
            {:ok, socket}

          {:error, reason} ->
            Logger.warning(
              "[dht] could not bind dedicated IPv6 socket port=#{port} addr=#{Acceptor.format_ip(v6_addr)} reason=#{inspect(reason)}"
            )

            {:ok, nil}
        end
    end
  end

  @spec bind_socket(port() | nil) :: :ok | {:error, term()}
  defp bind_socket(nil), do: :ok

  defp bind_socket(socket) do
    case :gen_udp.controlling_process(socket, self()) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  @spec maybe_bind_socket(port() | nil) :: :ok | {:error, term()}
  defp maybe_bind_socket(nil), do: :ok
  defp maybe_bind_socket(socket), do: bind_socket(socket)

  @spec select_socket(t(), :inet | :inet6) :: port() | nil
  defp select_socket(%__MODULE__{socket_v6: socket_v6}, :inet6) when is_port(socket_v6),
    do: socket_v6

  defp select_socket(%__MODULE__{socket_v4: socket_v4}, :inet6), do: socket_v4
  defp select_socket(%__MODULE__{socket_v4: socket_v4}, :inet), do: socket_v4
  defp select_socket(%__MODULE__{socket_v4: socket_v4}, _), do: socket_v4

  @spec socket_for_dest(t(), :inet.ip_address()) :: port()
  defp socket_for_dest(state, ip) do
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet
    select_socket(state, family)
  end

  @spec socket_family(t(), port()) :: :inet | :inet6
  defp socket_family(%__MODULE__{socket_v6: socket_v6}, socket) when socket == socket_v6,
    do: :inet6

  defp socket_family(%__MODULE__{}, _socket), do: :inet

  @spec get_peers_args(Torrent.hash()) :: keyword()
  defp get_peers_args(hash) do
    case dht_want() do
      nil -> [info_hash: hash]
      want -> [info_hash: hash, want: want]
    end
  end

  @spec dht_want() :: [String.t()] | nil
  defp dht_want do
    %{inet6: ip6} = Acceptor.primary_ips()

    if ip6 != nil, do: ["n4", "n6"], else: nil
  end

  @spec reply_node_fields(
          RoutingTables.t(),
          RoutingTable.node_id(),
          [String.t()] | nil,
          :inet | :inet6
        ) ::
          %{optional(:nodes) => binary(), optional(:nodes6) => binary()}
  defp reply_node_fields(tables, target, want, request_family) do
    %{}
    |> maybe_reply_nodes(:v4, tables, target, want, request_family)
    |> maybe_reply_nodes(:v6, tables, target, want, request_family)
  end

  @spec maybe_reply_nodes(
          map(),
          RoutingTables.family(),
          RoutingTables.t(),
          RoutingTable.node_id(),
          [String.t()] | nil,
          :inet | :inet6
        ) ::
          map()
  defp maybe_reply_nodes(acc, family, tables, target, want, request_family) do
    if include_want_family?(want, family, request_family) do
      key = if family == :v4, do: :nodes, else: :nodes6
      encode = if family == :v4, do: &Compact.encode_nodes/1, else: &Compact.encode_nodes6/1

      contacts =
        tables
        |> RoutingTables.closest_family(family, target, 8)
        |> RoutingTables.to_contacts()

      encoded = encode.(contacts)

      if encoded == <<>>, do: acc, else: Map.put(acc, key, encoded)
    else
      acc
    end
  end

  @spec include_want_family?(
          [String.t()] | nil,
          RoutingTables.family(),
          :inet | :inet6
        ) :: boolean()
  defp include_want_family?(nil, :v4, :inet), do: true
  defp include_want_family?(nil, :v6, :inet6), do: true
  defp include_want_family?(nil, _family, _request_family), do: false
  defp include_want_family?(want, :v4, _request_family) when is_list(want), do: "n4" in want
  defp include_want_family?(want, :v6, _request_family) when is_list(want), do: "n6" in want

  @spec peer_in_family?(Peer.t(), :inet | :inet6) :: boolean()
  defp peer_in_family?(%Peer{ip: ip}, :inet), do: tuple_size(ip) == 4
  defp peer_in_family?(%Peer{ip: ip}, :inet6), do: tuple_size(ip) == 8

  @spec maybe_put_query_want(KRPC.query(), keyword()) :: KRPC.query()
  defp maybe_put_query_want(query, args) do
    case Keyword.get(args, :want) do
      want when is_list(want) and want != [] -> Map.put(query, :want, want)
      _ -> query
    end
  end

  @spec contact_family_rank(:inet.ip_address()) :: 0 | 1
  defp contact_family_rank(ip) when tuple_size(ip) == 8, do: 0
  defp contact_family_rank(_ip), do: 1

  @spec compact_endpoint(:inet.ip_address(), :inet.port_number()) :: binary()
  defp compact_endpoint({_, _, _, _} = ip, port), do: Compact.encode_peer(ip, port)

  defp compact_endpoint({_, _, _, _, _, _, _, _} = ip, port),
    do: Compact.encode_ipv6_peer(ip, port)

  @spec maybe_put_token(map(), binary() | nil) :: map()
  defp maybe_put_token(response, token) when is_binary(token),
    do: Map.put(response, :token, token)

  defp maybe_put_token(response, nil), do: response

  @spec schedule_bootstrap() :: reference()
  defp schedule_bootstrap, do: Process.send_after(self(), :bootstrap, @bootstrap_after_ms)

  @spec schedule_token_rotate(non_neg_integer()) :: reference()
  defp schedule_token_rotate(ms), do: Process.send_after(self(), :rotate_tokens, ms)

  @spec schedule_refresh(non_neg_integer()) :: reference()
  defp schedule_refresh(ms), do: Process.send_after(self(), :refresh_buckets, ms)

  @spec schedule_persist(non_neg_integer()) :: reference()
  defp schedule_persist(ms), do: Process.send_after(self(), :persist_routing, ms)

  @spec trim_map(map(), pos_integer()) :: map()
  defp trim_map(map, max) when map_size(map) <= max, do: map

  defp trim_map(map, max) do
    map
    |> Enum.take(max)
    |> Map.new()
  end
end

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
  require Logger

  alias DHT.{
    Compact,
    Config,
    KRPC,
    Lookup,
    NodeId,
    PeerStore,
    RoutingTable,
    Token
  }

  @version Config.version_string()
  @token_rotate_ms 5 * 60 * 1_000
  @refresh_ms 15 * 60 * 1_000
  @bootstrap_after_ms 1_000
  @bootstrap_lookup_waits 12
  @bootstrap_lookup_wait_ms 500
  @min_routing_nodes 1
  @max_pending 256
  @max_announce_tokens 512
  @reannounce_interval_ms 15 * 60 * 1_000

  defstruct [
    :socket,
    :node_id,
    :port,
    routing_table: nil,
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
  @spec udp_socket() :: port() | nil
  def udp_socket do
    if enabled?(), do: GenServer.call(__MODULE__, :udp_socket, 5_000)
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

  @impl true
  def init(_opts) do
    node_id = NodeId.get()

    with {:ok, socket, port} <- open_socket(),
         :ok <- bind_socket(socket) do
      table = RoutingTable.new(node_id)
      tokens = Token.new()

      schedule_bootstrap()
      schedule_token_rotate(@token_rotate_ms)
      schedule_refresh(@refresh_ms)
      :ok = :inet.setopts(socket, active: :once)

      {:ok,
       %__MODULE__{
         socket: socket,
         node_id: node_id,
         port: port,
         routing_table: table,
         tokens: tokens
       }}
    else
      {:error, reason} ->
        Logger.warning("DHT disabled: could not bind UDP port reason=#{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, %__MODULE__{port: port} = state), do: {:reply, port, state}

  def handle_call(:udp_socket, _from, %__MODULE__{socket: socket} = state),
    do: {:reply, socket, state}

  def handle_call({:send_udp, ip, port, data}, _from, %__MODULE__{socket: socket} = state) do
    {:reply, :gen_udp.send(socket, ip, port, data), state}
  end

  def handle_call({:get_peers, hash, timeout}, from, state) do
    ref = make_ref()
    {:noreply, start_lookup(state, hash, ref, from, timeout)}
  end

  @impl true
  def handle_cast({:announce, hash, port}, state) do
    {:noreply, start_announce_lookup(state, hash, port)}
  end

  def handle_cast({:add_node, contact}, state) do
    table = RoutingTable.insert(state.routing_table, contact)
    {:noreply, ping_node(%{state | routing_table: table}, contact)}
  end

  def handle_cast({:seed_node, ip, port}, state) do
    # BEP 5 § BitTorrent Protocol Extension — learn node id from ping response.
    contact = %{id: <<0::160>>, ip: ip, port: port}
    {:noreply, ping_node(state, contact)}
  end

  @impl true
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

  def handle_info({:udp, socket, ip, port, packet}, %__MODULE__{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    {:noreply, handle_packet(state, ip, port, packet)}
  end

  def handle_info({:udp, _socket, _ip, _port, _packet}, state), do: {:noreply, state}

  def handle_info({:udp_error, socket, reason}, %__MODULE__{socket: socket} = state) do
    Logger.warning("DHT UDP error: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:query_timeout, tid}, state) do
    {pending, state} = pop_pending(state, tid)
    state = maybe_mark_bad(state, pending)
    state = maybe_lookup_step(state, pending)
    {:noreply, state}
  end

  def handle_info({:lookup_timeout, ref}, state) do
    case Map.get(state.lookups, ref) do
      nil ->
        {:noreply, state}

      %{purpose: :announce} = lookup ->
        {:noreply, finish_announce(state, ref, lookup)}

      %{from: from, peers: peers} when peers != [] ->
        GenServer.reply(from, {:ok, Enum.take(peers, Config.max_lookup_peers())})
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

  @spec handle_packet(t(), :inet.ip_address(), :inet.port_number(), binary()) :: t()
  defp handle_packet(state, ip, port, packet) do
    if UTP.Packet.utp_packet?(packet) do
      :ok = UTP.Dispatcher.dispatch(state.socket, ip, port, packet)
      state
    else
      handle_dht_packet(state, ip, port, packet)
    end
  end

  @spec handle_dht_packet(t(), :inet.ip_address(), :inet.port_number(), binary()) :: t()
  defp handle_dht_packet(state, ip, port, packet) do
    case KRPC.decode(packet) do
      {:ok, {:query, query}} ->
        handle_query(state, ip, port, query)

      {:ok, {:response, response}} ->
        handle_response(state, ip, port, response)

      {:ok, {:error, _error}} ->
        state

      {:error, _} ->
        state
    end
  end

  @spec handle_query(t(), :inet.ip_address(), :inet.port_number(), KRPC.query()) :: t()
  defp handle_query(state, ip, port, query) do
    contact = %{id: query.node_id, ip: ip, port: port}
    table = RoutingTable.insert(state.routing_table, contact, from_query: true)
    state = %{state | routing_table: table}

    case query.method do
      :ping ->
        reply_ping(state, ip, port, query.transaction_id)

      :find_node ->
        reply_find_node(state, ip, port, query)

      :get_peers ->
        reply_get_peers(state, ip, port, query)

      :announce_peer ->
        handle_announce_peer(state, ip, port, query)
    end
  end

  @spec reply_ping(t(), :inet.ip_address(), :inet.port_number(), binary()) :: t()
  defp reply_ping(state, ip, port, tid) do
    response = %{transaction_id: tid, node_id: state.node_id, version: @version}
    send_response(state, ip, port, response)
    state
  end

  @spec reply_find_node(t(), :inet.ip_address(), :inet.port_number(), KRPC.query()) :: t()
  defp reply_find_node(state, ip, port, %{transaction_id: tid, target: target}) do
    nodes =
      state.routing_table
      |> RoutingTable.closest(target, 8)
      |> RoutingTable.to_contacts()
      |> Compact.encode_nodes()

    response = %{
      transaction_id: tid,
      node_id: state.node_id,
      nodes: nodes,
      version: @version
    }

    send_response(state, ip, port, response)
    state
  end

  @spec reply_get_peers(t(), :inet.ip_address(), :inet.port_number(), KRPC.query()) :: t()
  defp reply_get_peers(state, ip, port, %{transaction_id: tid, info_hash: hash}) do
    token = Token.issue(state.tokens, ip)
    peers = PeerStore.get(state.peer_store, hash)

    response =
      if peers == [] do
        nodes =
          state.routing_table
          |> RoutingTable.closest(hash, 8)
          |> RoutingTable.to_contacts()
          |> Compact.encode_nodes()

        %{
          transaction_id: tid,
          node_id: state.node_id,
          nodes: nodes,
          token: token,
          version: @version
        }
      else
        values =
          peers
          |> Enum.map(fn %Peer{ip: peer_ip, port: peer_port} ->
            case Compact.encode_peer(peer_ip, peer_port) do
              blob when is_binary(blob) -> blob
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        %{
          transaction_id: tid,
          node_id: state.node_id,
          values: values,
          token: token,
          version: @version
        }
      end

    send_response(state, ip, port, response)
    state
  end

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

      not is_integer(peer_port) or peer_port not in 1..65535 ->
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

    case Map.pop(state.pending, tid) do
      {nil, _} ->
        state

      {pending, pending_map} ->
        Process.cancel_timer(pending.timer_ref)

        contact = %{id: response.node_id, ip: ip, port: port}

        table =
          state.routing_table
          |> RoutingTable.insert(contact)
          |> RoutingTable.mark_good(response.node_id, from_query: true)

        state = %{state | routing_table: table, pending: pending_map}
        peers = KRPC.response_peers(response)
        nodes = KRPC.response_nodes(response)

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
        packet = KRPC.encode_query(query)
        _ = :gen_udp.send(new_state.socket, node.ip, node.port, packet)
        {:ok, tid, new_state}
    end
  end

  @spec build_query(atom(), binary(), RoutingTable.node_id(), keyword()) :: KRPC.query()
  defp build_query(:ping, tid, node_id, _),
    do: %{method: :ping, transaction_id: tid, node_id: node_id, version: @version}

  defp build_query(:find_node, tid, node_id, args),
    do: %{
      method: :find_node,
      transaction_id: tid,
      node_id: node_id,
      target: Keyword.fetch!(args, :target),
      version: @version
    }

  defp build_query(:get_peers, tid, node_id, args),
    do: %{
      method: :get_peers,
      transaction_id: tid,
      node_id: node_id,
      info_hash: Keyword.fetch!(args, :info_hash),
      version: @version
    }

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
    state =
      Enum.reduce(Config.bootstrap_routers(), state, fn {host, port}, acc ->
        case :inet.gethostbyname(String.to_charlist(host)) do
          {:ok, {:hostent, _name, _aliases, _type, _len, ips}} ->
            bootstrap_ip(acc, hd(ips), port)

          _ ->
            acc
        end
      end)

    %{state | bootstrapped?: true}
  end

  @spec bootstrap_ip(t(), :inet.ip_address(), :inet.port_number()) :: t()
  defp bootstrap_ip(state, ip, port) do
    bootstrap_id = :crypto.strong_rand_bytes(20)
    contact = %{id: bootstrap_id, ip: ip, port: port}

    case send_query(state, contact, :find_node, target: state.node_id) do
      {:ok, _tid, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  @spec refresh_stale_buckets(t()) :: t()
  defp refresh_stale_buckets(state) do
    state.routing_table
    |> RoutingTable.stale_buckets()
    |> Enum.reduce(state, fn bucket, acc ->
      target = RoutingTable.random_id_in_bucket(bucket)

      case RoutingTable.closest(acc.routing_table, target, 1) do
        [node | _] ->
          case send_query(acc, node, :find_node, target: target) do
            {:ok, _tid, new_state} -> new_state
            {:error, _, new_state} -> new_state
          end

        [] ->
          acc
      end
    end)
  end

  # --- get_peers lookup (BEP 5 § Peer lookup) ---

  @spec start_lookup(t(), Torrent.hash(), reference(), GenServer.from(), pos_integer()) :: t()
  defp start_lookup(state, hash, ref, from, timeout) do
    shortlist = Lookup.initial_shortlist(state.routing_table, hash)

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
    shortlist = Lookup.initial_shortlist(state.routing_table, hash)
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

  defp bootstrap_delay_ms(%__MODULE__{routing_table: table}) do
    if RoutingTable.node_count(table) >= @min_routing_nodes,
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

      %{hash: hash, shortlist: shortlist, peers: peers} = lookup ->
        shortlist = Lookup.refresh_shortlist(state.routing_table, hash, shortlist)

        cond do
          peers != [] and Lookup.converged?(shortlist) ->
            finish_lookup_by_purpose(state, ref, lookup, peers)

          Lookup.converged?(shortlist) and peers == [] ->
            maybe_wait_for_bootstrap(state, ref, lookup, hash)

          true ->
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

      _ ->
        state
    end
  end

  # Defer lookup while bootstrap fills the routing table (BEP 5 § bootstrap before search).
  @spec maybe_wait_for_bootstrap(t(), reference(), map(), Torrent.hash()) :: t()
  defp maybe_wait_for_bootstrap(state, ref, lookup, hash) do
    waits = Map.get(lookup, :bootstrap_waits, 0)
    node_count = RoutingTable.node_count(state.routing_table)

    if waits < @bootstrap_lookup_waits and node_count < 8 do
      state = if state.bootstrapped?, do: state, else: bootstrap(state)

      updated =
        lookup
        |> Map.put(:shortlist, Lookup.initial_shortlist(state.routing_table, hash))
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
        case find_entry(acc.routing_table, id) do
          nil ->
            {acc, MapSet.put(q, id)}

          entry ->
            pending = %{type: :lookup, lookup_ref: ref, node_id: id}

            case send_query(acc, entry, :get_peers, [info_hash: hash], pending: pending) do
              {:ok, _tid, new_state} ->
                {new_state, MapSet.put(q, id)}

              {:error, _, new_state} ->
                table = RoutingTable.mark_bad(new_state.routing_table, id)
                {Map.put(new_state, :routing_table, table), MapSet.put(q, id)}
            end
        end
      end)

    updated =
      lookup
      |> Map.put(:shortlist, shortlist)
      |> Map.put(:peers, peers)
      |> Map.put(:queried, queried)

    %{state | lookups: Map.put(state.lookups, ref, updated)}
  end

  @spec finish_lookup(t(), reference(), [Peer.t()]) :: t()
  defp finish_lookup(state, ref, peers) do
    lookup = Map.get(state.lookups, ref)
    peers = peers |> Enum.take(Config.max_lookup_peers())
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
  defp dispatch_pending(state, %{type: :lookup, lookup_ref: ref}, peers, nodes) do
    case Map.get(state.lookups, ref) do
      nil ->
        state

      lookup ->
        merged = Lookup.merge_nodes(lookup.shortlist, nodes, lookup.hash)

        peers =
          (lookup.peers ++ peers)
          |> Enum.uniq_by(&{&1.ip, &1.port})
          |> Enum.take(Config.max_lookup_peers())

        updated = lookup |> Map.put(:shortlist, merged) |> Map.put(:peers, peers)
        state = %{state | lookups: Map.put(state.lookups, ref, updated)}
        Process.send(self(), {:lookup_step, ref}, [])
        state
    end
  end

  defp dispatch_pending(state, _pending, _peers, _nodes), do: state

  # --- announce_peer client (BEP 5 § announce after get_peers tokens) ---

  @spec finish_announce(t(), reference(), map()) :: t()
  defp finish_announce(state, ref, lookup) do
    hash = lookup.hash
    bt_port = lookup.bt_port
    node_count = map_size(lookup.announce_nodes)

    Logger.info(
      "[dht_announce] hash=#{Torrent.hex_encoded_hash(hash)} port=#{bt_port} nodes=#{node_count}"
    )

    state =
      Enum.reduce(lookup.announce_nodes, state, fn {{ip, port}, token}, acc ->
        node = %{id: <<0::160>>, ip: ip, port: port}

        case send_query(acc, node, :announce_peer,
               info_hash: hash,
               port: bt_port,
               token: token,
               implied_port: 0
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

  @spec record_lookup_announce_token(t(), map() | nil, :inet.ip_address(), :inet.port_number(), binary()) ::
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

  @spec merge_discovered_nodes(t(), [Compact.contact()]) :: t()
  defp merge_discovered_nodes(state, nodes) do
    nodes
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(state, fn node, acc ->
      %{acc | routing_table: RoutingTable.insert(acc.routing_table, node)}
    end)
  end

  @spec send_response(t(), :inet.ip_address(), :inet.port_number(), KRPC.response()) :: :ok
  defp send_response(state, ip, port, response) do
    _ = :gen_udp.send(state.socket, ip, port, KRPC.encode_response(response))
    :ok
  end

  @spec send_error(t(), :inet.ip_address(), :inet.port_number(), binary(), 201..204, String.t()) ::
          :ok
  defp send_error(state, ip, port, tid, code, message) do
    packet = KRPC.encode_error(%{transaction_id: tid, code: code, message: message})
    _ = :gen_udp.send(state.socket, ip, port, packet)
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

  @spec maybe_mark_bad(t(), map() | nil) :: t()
  # BEP 5 § bad nodes — lookup get_peers timeouts are inconclusive; do not poison the table.
  defp maybe_mark_bad(state, %{type: :lookup}), do: state

  defp maybe_mark_bad(state, %{node: %{id: id}}) when byte_size(id) == 20 do
    %{state | routing_table: RoutingTable.mark_bad(state.routing_table, id)}
  end

  defp maybe_mark_bad(state, %{node_id: id}) when byte_size(id) == 20 do
    %{state | routing_table: RoutingTable.mark_bad(state.routing_table, id)}
  end

  defp maybe_mark_bad(state, _), do: state

  @spec maybe_lookup_step(t(), map() | nil) :: t()
  defp maybe_lookup_step(state, %{type: :lookup, lookup_ref: ref}) do
    Process.send(self(), {:lookup_step, ref}, [])
    state
  end

  defp maybe_lookup_step(state, _), do: state

  @spec find_entry(RoutingTable.t(), RoutingTable.node_id()) :: RoutingTable.entry() | nil
  defp find_entry(table, id) do
    table
    |> RoutingTable.closest(id, 160)
    |> Enum.find(&(&1.id == id))
  end

  @spec transaction_id() :: binary()
  defp transaction_id, do: :crypto.strong_rand_bytes(2)

  @spec open_socket() :: {:ok, port(), :inet.port_number()} | {:error, term()}
  defp open_socket do
    case Config.port() do
      nil ->
        case Acceptor.open_udp() do
          {:ok, socket} ->
            {:ok, port} = :inet.port(socket)
            {:ok, socket, port}

          :error ->
            {:error, :no_udp_port}
        end

      port ->
        case :gen_udp.open(port, Acceptor.socket_options(:inet)) do
          {:ok, socket} -> {:ok, socket, port}
          {:error, _} = error -> error
        end
    end
  end

  @spec bind_socket(port()) :: :ok | {:error, term()}
  defp bind_socket(socket) do
    case :gen_udp.controlling_process(socket, self()) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  @spec schedule_bootstrap() :: reference()
  defp schedule_bootstrap, do: Process.send_after(self(), :bootstrap, @bootstrap_after_ms)

  @spec schedule_token_rotate(non_neg_integer()) :: reference()
  defp schedule_token_rotate(ms), do: Process.send_after(self(), :rotate_tokens, ms)

  @spec schedule_refresh(non_neg_integer()) :: reference()
  defp schedule_refresh(ms), do: Process.send_after(self(), :refresh_buckets, ms)

  @spec trim_map(map(), pos_integer()) :: map()
  defp trim_map(map, max) when map_size(map) <= max, do: map

  defp trim_map(map, max) do
    map |> Enum.take(max) |> Map.new()
  end
end

defmodule Peer.Controller do
  use GenServer
  use Via

  alias __MODULE__.{State, FastExtension}
  alias Peer.Sender
  alias Torrent.{Uploader, Downloads}

  import Peer, only: [make_key: 2, key_to_id: 1, key_to_hash: 1]

  # @spec start_link({Peer.id(), Torrent.hash(), port(), Peer.reserved()}) :: GenServer.on_start()
  def start_link([hash, id, socket, reserved]) do
    GenServer.start_link(
      __MODULE__,
      [hash, id, socket, reserved],
      name: via(make_key(hash, id))
    )
  end

  @spec have(Peer.key(), Torrent.index()) :: :ok
  def have(key, index), do: GenServer.cast(via(key), {:have, [index]})

  @spec interested(Peer.key(), Torrent.index()) :: :ok
  def interested(key, index),
    do: GenServer.cast(via(key), {:interested, [index]})

  @doc false
  @spec interested_sync(Peer.key(), Torrent.index()) :: :ok
  def interested_sync(key, index) do
    GenServer.call(via(key), {:interested, index})
  catch
    :exit, _ -> :ok
  end

  @spec cancel(Torrent.hash(), Peer.id(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          :ok
  def cancel(hash, id, index, begin, length) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:cancel, [index, begin, length]})
  end

  @spec seed(Peer.key()) :: :ok
  def seed(key), do: GenServer.cast(via(key), {:seed, []})

  @spec choke(Torrent.hash(), Peer.id()) :: :ok
  def choke(hash, id) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:choke, []})
  end

  @spec unchoke(Torrent.hash(), Peer.id()) :: :ok
  def unchoke(hash, id) do
    make_key(hash, id)
    |> via
    |> GenServer.cast({:unchoke, []})
  end

  @spec rank(Peer.key()) :: State.rank()
  def rank(key), do: GenServer.call(via(key), :rank)

  @spec has_index?(Peer.key(), Torrent.index()) :: boolean()
  def has_index?(key, index), do: GenServer.call(via(key), {:has_index?, index})

  @spec download_piece(Peer.key()) :: Torrent.index() | nil
  def download_piece(key) do
    GenServer.call(via(key), :download_piece)
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec stale_useless_pin?(Peer.key()) :: boolean()
  def stale_useless_pin?(key) do
    GenServer.call(via(key), :stale_useless_pin?)
  catch
    :exit, _ -> true
  end

  @spec has_all?(Peer.key()) :: boolean()
  def has_all?(key), do: GenServer.call(via(key), :has_all?)

  @spec seeder?(Peer.key()) :: boolean()
  def seeder?(key), do: has_all?(key)

  @spec reset_rank(Peer.key()) :: :ok
  def reset_rank(key), do: GenServer.cast(via(key), {:reset_rank, []})

  @doc false
  @spec eviction_info(Peer.key()) :: map() | :error
  def eviction_info(key) do
    GenServer.call(via(key), :eviction_info, 500)
  catch
    :exit, _ -> :error
  end

  @spec handle_choke(Peer.key()) :: :ok
  def handle_choke(key), do: GenServer.cast(via(key), {:handle_choke, []})

  @spec handle_unchoke(Peer.key()) :: :ok
  def handle_unchoke(key), do: GenServer.cast(via(key), {:handle_unchoke, []})

  @spec handle_interested(Peer.key()) :: :ok
  def handle_interested(key),
    do: GenServer.cast(via(key), {:handle_interested, []})

  @spec handle_not_interested(Peer.key()) :: :ok
  def handle_not_interested(key),
    do: GenServer.cast(via(key), {:handle_not_interested, []})

  @doc """
  Gracefully disconnects from a peer before shutdown.

  Sends cancel / not interested / choke per BEP 3, shuts down the TCP socket, then stops.
  """
  @spec disconnect(Peer.key()) :: :ok
  def disconnect(key) do
    GenServer.call(via(key), :disconnect, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec start_protocol(Peer.key()) :: :ok
  def start_protocol(key), do: GenServer.call(via(key), :start_protocol, 60_000)

  @doc false
  @spec metadata_session(Peer.key()) :: {:ok, map()} | :error
  def metadata_session(key) do
    GenServer.call(via(key), :metadata_session)
  catch
    :exit, _ -> :error
  end

  @spec ltep_session(Peer.key()) :: {:ok, Peer.LTEP.Session.t()} | :error
  def ltep_session(key) do
    GenServer.call(via(key), :ltep_session)
  catch
    :exit, _ -> :error
  end

  @doc false
  @spec metadata_capable(Peer.key()) :: {:ok, map()} | :error
  def metadata_capable(key) do
    GenServer.call(via(key), :metadata_capable)
  catch
    :exit, _ -> :error
  end

  @spec handle_have(Peer.key(), Torrent.index()) :: :ok
  def handle_have(key, index),
    do: GenServer.cast(via(key), {:handle_have, [index]})

  @spec handle_bitfield(Peer.key(), Torrent.bitfield()) :: :ok
  def handle_bitfield(key, bitfield),
    do: GenServer.cast(via(key), {:handle_bitfield, [bitfield]})

  @spec handle_request(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_request(key, index, begin, length) do
    GenServer.cast(via(key), {:handle_request, [index, begin, length]})
  end

  @spec handle_piece(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def handle_piece(key, index, begin, block) do
    hash = key_to_hash(key)

    if valid_piece_block?(hash, index, begin, block) do
      Downloads.response(hash, index, key_to_id(key), begin, block)
      GenServer.cast(via(key), {:handle_piece, [index, begin, byte_size(block)]})
    else
      GenServer.stop(via(key), {:shutdown, :protocol_error})
    end
  end

  @spec valid_piece_block?(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.block()) ::
          boolean()
  defp valid_piece_block?(hash, index, begin, block) when is_binary(block) do
    block_size = byte_size(block)
    max = Torrent.Downloads.piece_max_length()

    with true <- block_size > 0,
         true <- block_size <= max,
         pieces_count when is_integer(pieces_count) <- Torrent.get(hash, :pieces_count),
         true <- index >= 0 and index < pieces_count,
         piece_len when is_integer(piece_len) <- Torrent.Model.piece_length(hash, index),
         true <- begin >= 0 and begin + block_size <= piece_len do
      true
    else
      _ -> false
    end
  end

  @spec handle_cancel(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_cancel(key, index, begin, length) do
    Uploader.cancel(key_to_hash(key), key_to_id(key), index, begin, length)
  end

  @spec handle_port(Peer.key(), :inet.port_number()) :: :ok
  def handle_port(key, port),
    do: GenServer.cast(via(key), {:handle_port, [port]})

  @spec handle_have_all(Peer.key()) :: :ok
  def handle_have_all(key),
    do: GenServer.cast(via(key), {:handle_have_all, []})

  @spec handle_have_none(Peer.key()) :: :ok
  def handle_have_none(key),
    do: GenServer.cast(via(key), {:handle_have_none, []})

  @spec handle_suggest_piece(Peer.key(), Torrent.index()) :: :ok
  def handle_suggest_piece(key, index),
    do: GenServer.cast(via(key), {:handle_suggest_piece, [index]})

  @spec handle_reject(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def handle_reject(key, index, begin, length) do
    GenServer.cast(via(key), {:handle_reject, [index, begin, length]})
  end

  @spec handle_allowed_fast(Peer.key(), Torrent.index()) :: :ok
  def handle_allowed_fast(key, index),
    do: GenServer.cast(via(key), {:handle_allowed_fast, [index]})

  @spec handle_extended(Peer.key(), non_neg_integer(), binary()) :: :ok
  def handle_extended(key, extended_id, payload),
    do: GenServer.cast(via(key), {:handle_extended, [extended_id, payload]})

  @spec send_pex(Peer.key(), binary()) :: :ok
  def send_pex(key, payload) when is_binary(payload),
    do: GenServer.cast(via(key), {:send_pex, [payload]})

  def init([hash, id, socket, reserved]) do
    # The peer supervisor is one_for_all: a Sender exit tears this process down
    # with an exit signal, which skips terminate/2 unless exits are trapped —
    # and terminate is what returns this peer's bitfield contribution to
    # PiecesStatistic. Without it every remote-close leaked availability.
    Process.flag(:trap_exit, true)

    [status, count, downloaded, _piece_length] =
      Torrent.get(hash, [:peer_status, :pieces_count, :downloaded, :piece_length])

    now = System.monotonic_time(:millisecond)

    {:ok,
     %State{
       hash: hash,
       id: id,
       socket: socket,
       fast_extension: FastExtension.make(reserved),
       status: status,
       pieces_count: count,
       peer_reserved: reserved,
       downloaded_at_connect: downloaded,
       connected_at: now,
       last_block_at: now,
       downloaded_bytes: 0
     }}
  end

  def terminate({:shutdown, :protocol_error}, state) do
    Torrent.PiecesStatistic.remove_peer(state.hash, state.bitfield, state.pieces_count)
    Acceptor.malicious_peer(state.id)
  end

  def terminate(reason, %State{} = state) do
    # :shutdown / {:shutdown,_} are normal OTP stop paths (app teardown, swarm
    # cap eviction, supervisor restart). Logging them at :info floods mix test
    # outside ExUnit's per-test capture_log — Application children keep the
    # default Logger handler. Keep :info for unexpected disconnect reasons only.
    unless quiet_disconnect_reason?(reason) do
      require Logger

      Logger.info(
        "[peer_upload] peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} disconnect reason=#{inspect(reason)} interested_of_me=#{state.interested_of_me} choked=#{state.choke}"
      )
    end

    maybe_mark_productive_endpoint(state)
    Torrent.PiecesStatistic.remove_peer(state.hash, state.bitfield, state.pieces_count)
    :ok
  end

  @doc false
  @spec quiet_disconnect_reason?(term()) :: boolean()
  def quiet_disconnect_reason?(:normal), do: true
  def quiet_disconnect_reason?(:shutdown), do: true
  def quiet_disconnect_reason?({:shutdown, _}), do: true
  def quiet_disconnect_reason?(_), do: false

  # Micro-swarm: peers that already delivered blocks are scarce under CGNAT.
  # Soften DialBackoff, re-queue the endpoint (dial_done already removed it from
  # ConnectionManager's queue), and kick an immediate re-dial — otherwise kick
  # alone burns lottery timeouts on unrelated candidates while the known-good
  # peer sits nowhere until the next tracker announce.
  defp maybe_mark_productive_endpoint(%State{downloaded_bytes: n} = state) when n > 0 do
    case Peer.Transport.safe_peername(state.socket) do
      {:ok, {ip, port}} ->
        Peer.DialBackoff.mark_productive(state.hash, ip, port)
        Peer.ConnectionManager.offer_peers(state.hash, [%Peer{ip: ip, port: port}])
        Peer.ConnectionManager.kick(state.hash)

        require Logger

        ip_str = ip |> :inet.ntoa() |> to_string()

        Logger.info(
          "[peer_dial] warm_redial endpoint=#{ip_str}:#{port} hash=#{Torrent.hex_encoded_hash(state.hash)} downloaded=#{n}"
        )

      _ ->
        :ok
    end
  catch
    _, _ -> :ok
  end

  defp maybe_mark_productive_endpoint(_), do: :ok

  # With trap_exit, non-parent linked exits (socket port, spawned helpers)
  # arrive here; propagate abnormal ones so the connection still dies with
  # terminate/2 running.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_call(:rank, _, state), do: {:reply, State.rank(state), state}

  def handle_call({:has_index?, index}, _, state),
    do: {:reply, State.has_index?(state, index), state}

  def handle_call(:download_piece, _, state) do
    piece =
      case state.status do
        idx when is_integer(idx) -> idx
        _ -> nil
      end

    {:reply, piece, state}
  end

  def handle_call({:interested, index}, _, state) do
    case State.interested(state, index) do
      {:error, reason, state} -> {:stop, {:shutdown, reason}, state}
      state -> {:reply, :ok, state}
    end
  end

  def handle_call(:stale_useless_pin?, _, state),
    do: {:reply, State.stale_useless_pin?(state), state}

  def handle_call(:has_all?, _, state),
    do: {:reply, match?(%State{bitfield: :all}, state), state}

  def handle_call(:eviction_info, _, state),
    do: {:reply, State.eviction_info(state), state}

  def handle_call(:disconnect, _, %State{} = state) do
    {operations, state} = State.disconnect_operations(state)
    key = State.key(state)
    :ok = Sender.send_operations(key, operations)
    close_socket(state.socket)
    {:stop, :normal, state}
  end

  def handle_call(:start_protocol, _, %State{} = state) do
    state =
      state
      |> apply_protocol_startup(state.downloaded_at_connect, state.peer_reserved)
      |> Map.put(:downloaded_at_connect, nil)
      |> Map.put(:peer_reserved, nil)

    {:reply, :ok, state}
  end

  def handle_call(:metadata_session, _, %State{ltep: ltep} = state) when not is_nil(ltep) do
    ut = Magnet.UtMetadata.extension_name()

    reply =
      if Peer.LTEP.Session.peer_supports?(ltep, ut) do
        metadata_size =
          case Peer.LTEP.Session.peer_handshake(ltep).metadata_size do
            size when is_integer(size) and size > 0 -> size
            _ -> nil
          end

        peer_seeder? =
          match?(%State{bitfield: :all}, state) or complete_bitfield?(state)

        if peer_seeder? or peer_has_metadata?(metadata_size) do
          {:ok,
           %{
             ltep: ltep,
             metadata_size: metadata_size,
             unchoked?: not state.choke_me,
             seeder?: true
           }}
        else
          :error
        end
      else
        :error
      end

    {:reply, reply, state}
  end

  def handle_call(:metadata_session, _, state), do: {:reply, :error, state}

  def handle_call(:ltep_session, _, %State{ltep: ltep} = state) when not is_nil(ltep) do
    {:reply, {:ok, ltep}, state}
  end

  def handle_call(:ltep_session, _, state), do: {:reply, :error, state}

  def handle_call(:metadata_capable, _, %State{ltep: ltep} = state) when not is_nil(ltep) do
    ut = Magnet.UtMetadata.extension_name()

    reply =
      if Peer.LTEP.Session.peer_supports?(ltep, ut) do
        metadata_size =
          case Peer.LTEP.Session.peer_handshake(ltep).metadata_size do
            size when is_integer(size) and size > 0 -> size
            _ -> nil
          end

        peer_seeder? =
          match?(%State{bitfield: :all}, state) or complete_bitfield?(state)

        {:ok,
         %{
           ltep: ltep,
           metadata_size: metadata_size,
           unchoked?: not state.choke_me,
           seeder?: peer_seeder? or peer_has_metadata?(metadata_size)
         }}
      else
        :error
      end

    {:reply, reply, state}
  end

  def handle_call(:metadata_capable, _, state), do: {:reply, :error, state}

  defp close_socket(socket) when is_port(socket) do
    _ = :gen_tcp.shutdown(socket, :write)
    _ = :gen_tcp.close(socket)
    :ok
  end

  defp close_socket({:utp, _} = socket) do
    Peer.Transport.close(socket)
    :ok
  end

  defp close_socket(_), do: :ok

  @spec apply_protocol_startup(State.t(), non_neg_integer(), Peer.reserved()) :: State.t()
  defp apply_protocol_startup(state, downloaded, reserved) do
    # BEP 10: extension handshake must be the first post-handshake message when LTEP is used.
    {state, ltep_exts} =
      if Peer.extension_protocol?(reserved) do
        state = State.start_ltep(state)
        exts = ltep_extension_names(state)
        {state, exts}
      else
        {state, []}
      end

    state = maybe_send_dht_port(state, reserved)

    state =
      cond do
        metadata_leech_peer?(state.hash) ->
          leech_startup(state)

        true ->
          state
          |> maybe_leech_startup(downloaded)
          |> State.first_message(downloaded)
      end

    if ltep_exts != [] do
      require Logger

      Logger.info(
        "[ltep] peer=#{Peer.log_key(State.key(state))} hash=#{Torrent.hex_encoded_hash(state.hash)} extensions=#{inspect(ltep_exts)}"
      )
    end

    case state do
      %State{status: :seed, fast_extension: %FastExtension{}} ->
        State.send_allowed_fast(state)

      _ ->
        state
    end
  end

  @spec leech_startup(State.t()) :: State.t()
  defp leech_startup(state) do
    :ok = Sender.interested(make_key(state.hash, state.id))
    State.unchoke(state)
  end

  @spec maybe_leech_startup(State.t(), non_neg_integer()) :: State.t()
  defp maybe_leech_startup(state, downloaded) do
    if download_leech_startup?(state, downloaded), do: leech_startup(state), else: state
  end

  @spec download_leech_startup?(State.t(), non_neg_integer()) :: boolean()
  defp download_leech_startup?(state, downloaded) do
    downloaded == 0 and leeching?(state.hash) and state.status != :seed
  end

  @spec leeching?(Torrent.hash()) :: boolean()
  defp leeching?(hash) do
    case Torrent.get(hash, :left) do
      left when is_integer(left) and left > 0 -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @spec metadata_leech_peer?(Torrent.hash()) :: boolean()
  defp metadata_leech_peer?(hash) do
    Magnet.Bootstrap.active?(hash) and metadata_stub?(hash)
  end

  @spec metadata_stub?(Torrent.hash()) :: boolean()
  defp metadata_stub?(hash) do
    case Torrent.get(hash, [:last_index]) do
      [0] -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @spec ltep_extension_names(State.t()) :: [String.t()]
  defp ltep_extension_names(%State{ltep: nil}), do: []

  defp ltep_extension_names(%State{ltep: ltep}) do
    Peer.UtPex.extension_name()
    |> then(fn ut_pex ->
      names = if Peer.LTEP.Session.peer_supports?(ltep, ut_pex), do: [ut_pex], else: []

      if Peer.LTEP.Session.peer_supports?(ltep, Magnet.UtMetadata.extension_name()) do
        [Magnet.UtMetadata.extension_name() | names]
      else
        names
      end
    end)
  end

  # BEP 5 § BitTorrent Protocol Extension — tell DHT-capable peers our UDP port.
  @spec maybe_send_dht_port(State.t(), Peer.reserved()) :: State.t()
  defp maybe_send_dht_port(state, reserved) do
    if Peer.dht?(reserved) do
      case DHT.port() do
        port when is_integer(port) ->
          :ok = Sender.port(State.key(state), port)
          state

        _ ->
          state
      end
    else
      state
    end
  end

  def handle_cast({message, _}, %State{hash: hash, fast_extension: nil} = state)
      when message in [
             :handle_suggest_piece,
             :handle_allowed_fast,
             :handle_reject
           ] do
    if Magnet.Bootstrap.active?(hash) do
      {:noreply, state}
    else
      {:stop, {:shutdown, :protocol_error}, state}
    end
  end

  def handle_cast({fun, args}, state) do
    case apply(State, fun, [state | args]) do
      {:error, reason, state} ->
        {:stop, {:shutdown, reason}, state}

      state ->
        {:noreply, state}
    end
  end

  @spec complete_bitfield?(State.t()) :: boolean()
  defp complete_bitfield?(%State{bitfield: bitfield, pieces_count: count})
       when is_binary(bitfield) and is_integer(count) and count > 0 do
    Torrent.Bitfield.valid?(bitfield, count) and
      Torrent.Bitfield.count(bitfield, count) == count
  end

  defp complete_bitfield?(_), do: false

  @spec peer_has_metadata?(pos_integer() | nil) :: boolean()
  defp peer_has_metadata?(size) when is_integer(size) and size > 0, do: true
  defp peer_has_metadata?(_), do: false
end

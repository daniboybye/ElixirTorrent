defmodule Peer.Controller do
  @moduledoc """
  Per-peer GenServer: choke/unchoke, piece requests, LTEP extensions, and hash transfer.
  """

  use GenServer
  use Via

  import Peer, only: [make_key: 2, key_to_id: 1, key_to_hash: 1]

  alias __MODULE__.{State, FastExtension}
  alias Peer.LTEP.Session
  alias Peer.Sender
  alias Torrent.{Downloads, Uploader}

  @spec start_link([Torrent.hash() | Peer.id() | Peer.Transport.socket() | Peer.reserved()]) ::
          GenServer.on_start()
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
    |> via()
    |> GenServer.cast({:cancel, [index, begin, length]})
  end

  @spec seed(Peer.key()) :: :ok
  def seed(key), do: GenServer.cast(via(key), {:seed, []})

  @doc false
  @spec superseed_assign(Peer.key(), Torrent.index() | nil) :: :ok
  def superseed_assign(key, index),
    do: GenServer.cast(via(key), {:superseed_assign, [index]})

  @spec choke(Torrent.hash(), Peer.id()) :: :ok
  def choke(hash, id) do
    make_key(hash, id)
    |> via()
    |> GenServer.cast({:choke, []})
  end

  @spec unchoke(Torrent.hash(), Peer.id()) :: :ok
  def unchoke(hash, id) do
    make_key(hash, id)
    |> via()
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

  @doc """
  Reports that a piece this peer supplied on its own failed its hash check.

  Repeated failures disconnect the peer — see `Peer.Controller.State.hash_check_failed/2`.
  """
  @spec hash_check_failed(Peer.key(), Torrent.index()) :: :ok
  def hash_check_failed(key, index),
    do: GenServer.cast(via(key), {:hash_check_failed, [index]})

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
  @spec disconnect(Peer.key(), term()) :: :ok
  def disconnect(key, reason \\ :normal) do
    GenServer.call(via(key), {:disconnect, reason}, 5_000)
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

  @spec ltep_session(Peer.key()) :: {:ok, Session.t()} | :error
  def ltep_session(key) do
    GenServer.call(via(key), :ltep_session)
  catch
    :exit, _ -> :error
  end

  @doc false
  @spec holepunch_relay_info(Peer.key()) ::
          {:ok, Session.t(), MapSet.t({:inet.ip_address(), :inet.port_number()})}
          | :error
  def holepunch_relay_info(key) do
    GenServer.call(via(key), :holepunch_relay_info)
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
      require Logger

      Logger.debug(
        "[peer_wire] peer=#{Peer.log_id(key_to_id(key))} hash=#{Torrent.hex_encoded_hash(hash)} rejected=piece_bounds index=#{index} begin=#{begin} bytes=#{byte_size(block)} pieces=#{inspect(Torrent.get(hash, :pieces_count))} piece_len=#{inspect(Torrent.Model.piece_length(hash, index))}"
      )

      GenServer.stop(via(key), {:shutdown, :protocol_error})
    end
  end

  @spec valid_piece_block?(Torrent.hash(), Torrent.index(), Torrent.begin(), Torrent.block()) ::
          boolean()
  defp valid_piece_block?(hash, index, begin, block) when is_binary(block) do
    block_size = byte_size(block)
    max = Torrent.Downloads.piece_max_length()

    valid_block_size?(block_size, max) and
      valid_piece_bounds?(hash, index, begin, block_size)
  end

  @spec valid_block_size?(non_neg_integer(), pos_integer()) :: boolean()
  defp valid_block_size?(block_size, max) do
    block_size > 0 and block_size <= max
  end

  @spec valid_piece_bounds?(Torrent.hash(), Torrent.index(), Torrent.begin(), non_neg_integer()) ::
          boolean()
  defp valid_piece_bounds?(hash, index, begin, block_size) do
    with pieces_count when is_integer(pieces_count) <- Torrent.get(hash, :pieces_count),
         true <- index >= 0 and index < pieces_count,
         piece_len when is_integer(piece_len) <- Torrent.Model.piece_length(hash, index) do
      begin >= 0 and begin + block_size <= piece_len
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

  @spec handle_hash_request(Peer.key(), Peer.HashWire.t()) :: :ok
  def handle_hash_request(key, %Peer.HashWire{} = req),
    do: GenServer.cast(via(key), {:handle_hash_request, [req]})

  @spec handle_hashes(Peer.key(), Peer.HashWire.t(), binary()) :: :ok
  def handle_hashes(key, %Peer.HashWire{} = req, hashes) when is_binary(hashes),
    do: GenServer.cast(via(key), {:handle_hashes, [req, hashes]})

  @spec handle_hash_reject(Peer.key(), Peer.HashWire.t()) :: :ok
  def handle_hash_reject(key, %Peer.HashWire{} = req),
    do: GenServer.cast(via(key), {:handle_hash_reject, [req]})

  @doc """
  Sends a correlated outbound BEP 52 hash request to a v2-capable peer.

  Returns `{:ok, ref}`; results arrive as `{:peer_hash_transfer, ref, result}`.
  No production caller uses this yet; hybrid downloads deliberately keep their
  established SHA-1 piece-verification path.
  """
  @spec request_hashes(Peer.key(), Peer.HashWire.t(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def request_hashes(key, %Peer.HashWire{} = req, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(via(key), {:request_hashes, req, timeout, self()}, timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, _ -> {:error, :noproc}
  end

  @spec peer_v2_support?(Peer.key()) :: boolean()
  def peer_v2_support?(key) do
    GenServer.call(via(key), :peer_v2_support?)
  catch
    :exit, _ -> false
  end

  @spec send_pex(Peer.key(), binary()) :: :ok
  def send_pex(key, payload) when is_binary(payload),
    do: GenServer.cast(via(key), {:send_pex, [payload]})

  @doc false
  @spec send_pex_snapshot(Peer.key(), %{Peer.UtPex.endpoint() => Peer.UtPex.Entry.t()}) :: :ok
  def send_pex_snapshot(key, snapshot) when is_map(snapshot),
    do: GenServer.cast(via(key), {:apply_pex_snapshot, [snapshot]})

  @doc false
  @spec pex_entry(Peer.key()) :: {:ok, Peer.UtPex.Entry.t()} | :error
  def pex_entry(key) do
    GenServer.call(via(key), :pex_entry, 500)
  catch
    :exit, _ -> :error
  end

  @doc false
  @spec set_connection_origin(Peer.key(), :inbound | :outbound) :: :ok
  def set_connection_origin(key, origin) when origin in [:inbound, :outbound] do
    GenServer.cast(via(key), {:set_connection_origin, [origin]})
  catch
    :exit, _ -> :ok
  end

  @spec init([Torrent.hash() | Peer.id() | Peer.Transport.socket() | Peer.reserved()]) ::
          {:ok, State.t()}
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
       peer_v2_support?: Peer.v2_support?(reserved),
       downloaded_at_connect: downloaded,
       connected_at: now,
       last_block_at: now,
       downloaded_bytes: 0
     }}
  end

  @spec terminate(term(), State.t()) :: :ok
  def terminate({:shutdown, :protocol_error} = reason, state) do
    note_disconnect_reason(state, reason)
    State.notify_hash_request_disconnect(state, :protocol_error)
    Torrent.Superseed.release(state.hash, state.id)
    Torrent.PiecesStatistic.remove_peer(state.hash, state.bitfield, state.pieces_count)

    require Logger

    Logger.debug(
      "[peer_wire] banned peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} cause=controller_protocol_error"
    )

    Acceptor.malicious_peer(state.id)
  end

  def terminate(reason, %State{} = state) do
    note_disconnect_reason(state, reason)
    State.record_pex_recent_disconnect(state, reason)
    State.notify_hash_request_disconnect(state, reason)
    # :shutdown / {:shutdown,_} are normal OTP stop paths (app teardown, swarm
    # cap eviction, supervisor restart). Logging them at :info floods mix test
    # outside ExUnit's per-test capture_log — Application children keep the
    # default Logger handler. Keep :info for unexpected disconnect reasons only.
    unless quiet_disconnect_reason?(reason) do
      require Logger

      Logger.debug(
        "[peer_upload] peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} disconnect reason=#{inspect(reason)} interested_of_me=#{state.interested_of_me} choked=#{state.choke}"
      )
    end

    maybe_mark_productive_endpoint(state)
    Torrent.Superseed.release(state.hash, state.id)
    Torrent.PiecesStatistic.remove_peer(state.hash, state.bitfield, state.pieces_count)
    :ok
  end

  # Our supervisor is auto_shutdown, so it exits with a bare `:shutdown` and
  # Peer.Endpoints — which monitors it, not us — cannot see this reason unless we
  # hand it over first. terminate/2 runs before the supervisor exits, so the note
  # is in place by the time the :DOWN lands.
  @spec note_disconnect_reason(State.t(), term()) :: :ok
  defp note_disconnect_reason(%State{socket: nil}, _reason), do: :ok

  defp note_disconnect_reason(%State{} = state, reason) do
    case Peer.Transport.safe_peername(state.socket) do
      {:ok, {ip, port}} -> Peer.Endpoints.note_disconnect_reason(state.hash, ip, port, reason)
      _ -> :ok
    end
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

        ip_str =
          ip
          |> :inet.ntoa()
          |> to_string()

        Logger.debug(
          "[peer_dial] warm_redial endpoint=#{ip_str}:#{port} hash=#{Torrent.hex_encoded_hash(state.hash)} downloaded=#{n}"
        )

      _ ->
        :ok
    end
  catch
    _, _ -> :ok
  end

  defp maybe_mark_productive_endpoint(_), do: :ok

  @spec stop_reason(term()) :: term()
  defp stop_reason({:shutdown, _} = r), do: r
  defp stop_reason(:normal), do: :normal
  defp stop_reason(other), do: other

  @spec maybe_claim_peer_id_for_pex(State.t()) :: {:ok, State.t()} | {:duplicate, State.t()}
  defp maybe_claim_peer_id_for_pex(%State{} = state) do
    with {:ok, {ip, port}} <- Peer.Transport.safe_peername(state.socket),
         :ok <- Peer.Endpoints.claim_peer_id(state.hash, state.id, ip, port, self()) do
      {:ok, state}
    else
      {:duplicate, _} -> {:duplicate, state}
      _ -> {:ok, state}
    end
  catch
    _, _ -> {:ok, state}
  end

  @spec handle_info(term(), State.t()) ::
          {:noreply, State.t()} | {:stop, term(), State.t()}
  def handle_info(:pex_initial_snapshot, %State{} = state) do
    if state.pex_outbound.initial_pending? and not state.pex_outbound.initial_sent? do
      key = State.key(state)
      hash = state.hash

      _ =
        Task.start(fn ->
          current =
            try do
              Peer.UtPex.snapshot_map(hash, exclude_key: key)
            catch
              :exit, _ -> %{}
            end

          send_pex_snapshot(key, current)
        end)
    end

    {:noreply, state}
  end

  # With trap_exit, non-parent linked exits (socket port, spawned helpers)
  # arrive here; propagate abnormal ones so the connection still dies with
  # terminate/2 running.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info({:hash_request_timeout, ref}, state) do
    case State.drop_hash_request(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {pending, state} ->
        Peer.HashTransfer.notify(pending.caller, ref, {:timeout, pending.request})
        {:noreply, state}
    end
  end

  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, term(), State.t()}
          | {:stop, term(), State.t()}
          | {:stop, term(), term(), State.t()}
  def handle_call({:complete_upload, index, begin, length, block}, _from, state) do
    {reply, state} = State.complete_upload(state, index, begin, length, block)
    {:reply, reply, state}
  end

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
    {:reply, :ok, State.interested(state, index)}
  end

  def handle_call(:stale_useless_pin?, _, state),
    do: {:reply, State.stale_useless_pin?(state), state}

  def handle_call(:has_all?, _, state),
    do: {:reply, state.bitfield == :all or complete_bitfield?(state), state}

  def handle_call(:eviction_info, _, state),
    do: {:reply, State.eviction_info(state), state}

  def handle_call({:disconnect, reason}, _, %State{} = state) do
    {operations, state} = State.disconnect_operations(state)
    key = State.key(state)
    :ok = Sender.send_operations(key, operations)
    # Resource-limit/no-interest exits must capture peername before closing the
    # socket; terminate/2 runs after close and can no longer recover the endpoint.
    State.record_pex_recent_disconnect(state, stop_reason(reason))
    close_socket(state.socket)
    {:stop, stop_reason(reason), state}
  end

  def handle_call(:start_protocol, _, %State{} = state) do
    state =
      state
      |> apply_protocol_startup(state.downloaded_at_connect, state.peer_reserved)
      |> Map.put(:downloaded_at_connect, nil)
      |> Map.put(:peer_reserved, nil)
      |> maybe_schedule_pex_initial()

    case maybe_claim_peer_id_for_pex(state) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:duplicate, state} ->
        State.record_pex_recent_disconnect(state, {:shutdown, :duplicate_peer})
        {:stop, {:shutdown, :duplicate_peer}, {:error, :duplicate_peer}, state}
    end
  end

  def handle_call(:metadata_session, _, %State{ltep: ltep} = state) when not is_nil(ltep) do
    ut = Magnet.UtMetadata.extension_name()

    reply =
      if Session.peer_supports?(ltep, ut) do
        metadata_size =
          case Session.peer_handshake(ltep).metadata_size do
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

  def handle_call(
        :holepunch_relay_info,
        _,
        %State{ltep: ltep, holepunch: %{pex_endpoints: endpoints}} = state
      )
      when not is_nil(ltep) do
    {:reply, {:ok, ltep, endpoints}, state}
  end

  def handle_call(:holepunch_relay_info, _, state), do: {:reply, :error, state}

  def handle_call(:metadata_capable, _, %State{ltep: ltep} = state) when not is_nil(ltep) do
    ut = Magnet.UtMetadata.extension_name()

    reply =
      if Session.peer_supports?(ltep, ut) do
        metadata_size =
          case Session.peer_handshake(ltep).metadata_size do
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

  def handle_call(:peer_v2_support?, _, state),
    do: {:reply, state.peer_v2_support?, state}

  def handle_call(:pex_entry, _, state), do: {:reply, State.pex_entry(state), state}

  def handle_call({:request_hashes, req, timeout, caller}, _, state) do
    case State.start_hash_request(state, req, caller, timeout) do
      {:ok, ref, state} -> {:reply, {:ok, ref}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

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
      if metadata_leech_peer?(state.hash) do
        leech_startup(state)
      else
        state
        |> maybe_leech_startup(downloaded)
        |> State.first_message(downloaded)
      end

    if ltep_exts != [] do
      require Logger

      Logger.debug(
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
      names = if Session.peer_supports?(ltep, ut_pex), do: [ut_pex], else: []

      if Session.peer_supports?(ltep, Magnet.UtMetadata.extension_name()) do
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

  @spec maybe_schedule_pex_initial(State.t()) :: State.t()
  defp maybe_schedule_pex_initial(%State{} = state) do
    if State.pex_initial_needed?(state) do
      send(self(), :pex_initial_snapshot)
      State.mark_pex_initial_pending(state)
    else
      state
    end
  end

  @spec handle_cast(term(), State.t()) ::
          {:noreply, State.t()} | {:stop, term(), State.t()}
  def handle_cast({:handle_extended, [0, payload]}, %State{} = state) do
    state =
      state
      |> State.handle_extended(0, payload)
      |> maybe_schedule_pex_initial()

    {:noreply, state}
  end

  # BEP 6 sends these only once both sides advertised the Fast extension, and we
  # do advertise it, so a peer sending one without it is at odds with the spec.
  # Tearing the connection down was still the wrong answer, because terminate/2
  # also blacklists the peer ID for every torrent: 71 of 98 disconnects in one
  # three-minute window, all of them qBittorrent and Transmission builds that do
  # support Fast, on a host whose torrents run on 1-8 peers.
  #
  # `have all` / `have none` are self-describing — they carry what a full or empty
  # bitfield carries — so they fall through to the normal handler. What is left is
  # advisory (`suggest piece`, `allowed fast`) or self-healing (`reject`, which the
  # request timeout already covers), so ignoring it costs nothing.
  def handle_cast({message, _}, %State{fast_extension: nil} = state)
      when message in [:handle_suggest_piece, :handle_allowed_fast, :handle_reject] do
    require Logger

    Logger.debug(
      "[peer_wire] peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} ignored=#{message} reason=fast_not_negotiated"
    )

    {:noreply, state}
  end

  def handle_cast({fun, args}, state) do
    case apply(State, fun, [state | args]) do
      {:error, reason, state} ->
        # Which wire message reached this verdict, not just that something did:
        # a :protocol_error here ends the connection and blacklists the peer, and
        # the reason alone is shared by a dozen rules.
        require Logger

        Logger.debug(
          "[peer_wire] peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} rejected=#{fun} reason=#{inspect(reason)}"
        )

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

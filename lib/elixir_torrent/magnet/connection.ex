defmodule Magnet.Connection do
  @moduledoc false

  require Logger

  @pstr "BitTorrent protocol"
  @pstrlen <<byte_size(@pstr)>>
  @handshake_length 68
  @connect_timeout 8_000
  @utp_connect_timeout_ms 10_000
  @recv_timeout 60_000
  @reserved Magnet.Peer.reserved()
  @ltep_message_id Peer.LTEP.message_id()
  @ltep_handshake_id Peer.LTEP.handshake_id()
  @interested_id 2
  @choke_id 0
  @unchoke_id 1
  @ut_metadata Peer.LTEP.Extension.name(Magnet.UtMetadata.Extension)
  @unchoke_stable_ms 500
  # Brief drain of early BEP 3 traffic after LTEP; do not wait for unchoke (BEP 9).
  @prime_inbound_ms 0
  @unchoke_wait_ms 45_000
  @controller_unchoke_poll_ms 200
  # Largest BEP 9 metadata piece on wire is ~16 KiB dict + 16 KiB data; cap below 1 MiB.
  @max_wire_message_length 1_048_576
  # Large ut_metadata data messages are ~16 KiB; never use the 1s poll cap for body reads.
  @wire_body_timeout_ms 30_000

  defstruct [
    :socket,
    :peer_key,
    :ltep,
    :metadata_size,
    peer: nil,
    transport: :tcp,
    unchoked?: false,
    unchoke_since: nil
  ]

  @type transport :: :tcp | :utp | :swarm

  @type t :: %__MODULE__{
          socket: Peer.Transport.socket() | nil,
          peer_key: Peer.key() | nil,
          ltep: Peer.LTEP.Session.t(),
          metadata_size: pos_integer() | nil,
          peer: Peer.t() | nil,
          transport: transport()
        }

  @doc """
  Opens a TCP or uTP session (TCP first, uTP fallback), completes BEP 3 + BEP 10
  handshakes, and returns a connection ready to exchange BEP 9 `ut_metadata` messages.

  Returns `{:error, :no_extension_protocol}` when the peer did not set BEP 10 bit 20,
  or `{:error, :no_ut_metadata}` when the peer's extension handshake omits `ut_metadata`.
  """
  @spec open(Peer.t(), Torrent.hash()) :: {:ok, t()} | {:error, term()}
  def open(%Peer{} = peer, hash) do
    opts = Acceptor.connect_options(family_for_ip(peer.ip))

    case connect_tcp(peer.ip, peer.port, opts) do
      {:ok, socket} ->
        Logger.debug(
          "[magnet_ut] connect transport=tcp endpoint=#{inspect({peer.ip, peer.port})}"
        )

        do_open_with_transport(peer, hash, socket, :tcp)

      {:error, tcp_reason} ->
        case connect_utp(peer.ip, peer.port) do
          {:ok, socket} ->
            Logger.info(
              "[magnet_ut] connect transport=utp endpoint=#{inspect({peer.ip, peer.port})}"
            )

            do_open_with_transport(peer, hash, socket, :utp)

          {:error, _} ->
            {:error, tcp_reason}
        end
    end
  catch
    :exit, reason ->
      {:error, reason}
  end

  @doc false
  @spec open_swarm(Peer.key(), map()) :: {:ok, t()} | {:error, term()}
  def open_swarm(key, info) when is_tuple(key) and is_map(info) do
    with :ok <- Peer.Sender.interested(key),
         {:ok, info} <- wait_controller_ready(key, info),
         :ok <- Peer.Sender.deactivate(key),
         true <- Peer.LTEP.Session.peer_supports?(info.ltep, @ut_metadata) do
      metadata_size = metadata_size_from_ltep(info.ltep) || info.metadata_size
      now_ms = System.monotonic_time(:millisecond)

      unchoked? = info.unchoked? == true

      conn = %__MODULE__{
        socket: nil,
        peer_key: key,
        ltep: info.ltep,
        metadata_size: metadata_size,
        transport: :swarm,
        peer: nil,
        unchoked?: unchoked?,
        unchoke_since: if(unchoked?, do: now_ms, else: nil)
      }

      log_ltep_ready_swarm(key, conn.ltep, metadata_size)

      Logger.info(
        "[magnet_ut] metadata_ready transport=swarm endpoint=peer=#{Peer.log_key(key)} unchoked=#{unchoked?}"
      )

      {:ok, conn}
    else
      false ->
        close_swarm(key)
        {:error, :no_ut_metadata}

      {:error, reason} = error ->
        step =
          case reason do
            :metadata_unavailable -> :controller_ready
            :choked -> :controller_unchoke
            _ -> :controller_ready
          end

        Logger.info(
          "[magnet_ut] open_swarm_fail endpoint=peer=#{Peer.log_key(key)} step=#{step} reason=#{inspect(normalize_peer_error(reason))}"
        )

        close_swarm(key)
        error

      other ->
        Logger.info(
          "[magnet_ut] open_swarm_fail endpoint=peer=#{Peer.log_key(key)} step=precondition reason=#{inspect(other)}"
        )

        close_swarm(key)
        {:error, other}
    end
  end

  @doc false
  @spec close_swarm(Peer.key()) :: :ok
  def close_swarm(key) when is_tuple(key) do
    _ = Peer.Sender.activate(key)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec fetch_info(t(), Torrent.hash()) :: {:ok, map(), binary()} | {:error, term()}
  def fetch_info(%__MODULE__{} = conn, hash), do: download_all_pieces(conn, hash)

  @spec do_open_with_transport(Peer.t(), Torrent.hash(), Peer.Transport.socket(), transport()) ::
          {:ok, t()} | {:error, term()}
  defp do_open_with_transport(%Peer{} = peer, hash, socket, transport) do
    case do_open(socket, peer, hash, transport) do
      {:ok, _} = ok ->
        ok

      {:error, _} = error ->
        safe_close(socket)
        error
    end
  end

  @spec connect_tcp(:inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, Peer.Transport.socket()} | {:error, term()}
  defp connect_tcp(ip, port, opts) do
    case Peer.Transport.connect(ip, port, Keyword.put(opts, :transport, :tcp), @connect_timeout) do
      {:ok, socket} when is_port(socket) ->
        :ok = Acceptor.apply_tcp_performance(socket)
        {:ok, socket}

      other ->
        other
    end
  end

  @spec connect_utp(:inet.ip_address(), :inet.port_number()) ::
          {:ok, Peer.Transport.socket()} | {:error, term()}
  defp connect_utp(ip, port) do
    try do
      UTP.Dispatcher.connect(ip, port, [], @utp_connect_timeout_ms)
    catch
      :exit, _ -> {:error, :timeout}
    end
  end

  @spec do_open(Peer.Transport.socket(), Peer.t(), Torrent.hash(), transport()) ::
          {:ok, t()} | {:error, term()}
  defp do_open(socket, peer, hash, transport) do
    with :ok <- handshake_exchange(socket, hash),
         {:ok, ltep} <- ltep_handshake_exchange(socket),
         :ok <- send_interested(socket),
         true <- Peer.LTEP.Session.peer_supports?(ltep, @ut_metadata) do
      metadata_size = metadata_size_from_ltep(ltep)

      log_ltep_ready(peer, ltep, metadata_size, transport)

      with {:ok, conn} <-
             prime_inbound_messages(%__MODULE__{
               socket: socket,
               peer_key: nil,
               ltep: ltep,
               metadata_size: metadata_size,
               transport: transport,
               peer: peer,
               unchoked?: false,
               unchoke_since: nil
             }) do
        {:ok, conn}
      end
    else
      false -> {:error, :no_ut_metadata}
      nil -> {:error, :no_ut_metadata}
      {:error, :no_extension_protocol} -> {:error, :no_extension_protocol}
      {:error, _} = error -> error
      _ -> {:error, :protocol_error}
    end
  end

  # Poll LTEP metadata_size while Sender is still active (BEP 9: ut_metadata is
  # independent of the piece choke; do not wait for unchoke).
  @spec wait_controller_ready(Peer.key(), map()) :: {:ok, map()} | {:error, term()}
  defp wait_controller_ready(key, info) do
    deadline = System.monotonic_time(:millisecond) + @unchoke_wait_ms
    do_wait_controller_ready(key, info, deadline)
  end

  @spec do_wait_controller_ready(Peer.key(), map(), integer()) :: {:ok, map()} | {:error, term()}
  defp do_wait_controller_ready(key, info, deadline) do
    info = refresh_swarm_info(key, info)
    metadata_size = metadata_size_from_ltep(info.ltep) || info.metadata_size

    cond do
      is_integer(metadata_size) and metadata_size > 0 ->
        Logger.info(
          "[magnet_ut] controller_ready transport=swarm endpoint=peer=#{Peer.log_key(key)} metadata_size=#{metadata_size} unchoked=#{inspect(info.unchoked?)}"
        )

        {:ok, Map.put(info, :metadata_size, metadata_size)}

      metadata_seeder?(info) ->
        Logger.info(
          "[magnet_ut] controller_ready transport=swarm endpoint=peer=#{Peer.log_key(key)} metadata_size=unknown seeder=true unchoked=#{inspect(info.unchoked?)}"
        )

        {:ok, info}

      Peer.LTEP.Session.peer_supports?(info.ltep, @ut_metadata) ->
        # BEP 9: ut_metadata peers may omit metadata_size in LTEP; probe piece 0 and
        # learn total_size from the data message (download_all_pieces/2 nil clause).
        Logger.info(
          "[magnet_ut] controller_ready transport=swarm endpoint=peer=#{Peer.log_key(key)} metadata_size=unknown ut_metadata=true unchoked=#{inspect(info.unchoked?)}"
        )

        {:ok, info}

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.info(
          "[magnet_ut] controller_ready_timeout transport=swarm endpoint=peer=#{Peer.log_key(key)} metadata_size=#{inspect(metadata_size)} unchoked=#{inspect(info.unchoked?)}"
        )

        {:error, :metadata_unavailable}

      true ->
        Process.sleep(@controller_unchoke_poll_ms)
        do_wait_controller_ready(key, info, deadline)
    end
  catch
    :exit, reason -> {:error, normalize_peer_error(reason)}
  end

  @spec metadata_seeder?(map()) :: boolean()
  defp metadata_seeder?(info), do: info[:seeder?] == true or info.seeder? == true

  defp metadata_size_from_ltep(ltep) do
    case Peer.LTEP.Session.peer_handshake(ltep).metadata_size do
      size when is_integer(size) and size > 0 -> size
      _ -> nil
    end
  end

  # Sender deactivation can lag behind a wire unchoke already processed by the controller.
  @spec refresh_swarm_info(Peer.key(), map()) :: map()
  defp refresh_swarm_info(key, info) do
    case Peer.Controller.metadata_capable(key) do
      {:ok, fresh} ->
        Map.merge(info, %{
          unchoked?: fresh.unchoked? == true,
          metadata_size: fresh.metadata_size || info.metadata_size,
          ltep: fresh.ltep || info.ltep,
          seeder?: fresh.seeder? == true or info[:seeder?] == true
        })

      _ ->
        info
    end
  catch
    :exit, _ -> info
  end

  defp log_ltep_ready(%Peer{ip: ip, port: port}, ltep, metadata_size, transport) do
    peer_ut = Peer.LTEP.Session.peer_extension_id(ltep, @ut_metadata)
    local_ut = Peer.LTEP.Session.local_extension_id(ltep, @ut_metadata)

    Logger.info(
      "[magnet_ut] handshake ok transport=#{transport} endpoint=#{inspect({ip, port})} peer_ut_id=#{inspect(peer_ut)} local_ut_id=#{inspect(local_ut)} metadata_size=#{inspect(metadata_size)}"
    )
  end


  defp log_ltep_ready_swarm(key, ltep, metadata_size) do
    peer_ut = Peer.LTEP.Session.peer_extension_id(ltep, @ut_metadata)
    local_ut = Peer.LTEP.Session.local_extension_id(ltep, @ut_metadata)

    Logger.info(
      "[magnet_ut] handshake ok transport=swarm endpoint=peer=#{Peer.log_key(key)} peer_ut_id=#{inspect(peer_ut)} local_ut_id=#{inspect(local_ut)} metadata_size=#{inspect(metadata_size)}"
    )
  end

  defp safe_close(nil), do: :ok

  defp safe_close(socket) do
    Peer.Transport.close(socket)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(%__MODULE__{transport: :swarm, peer_key: key}) when not is_nil(key) do
    close_swarm(key)
  end

  def close(%__MODULE__{socket: socket}) when not is_nil(socket) do
    safe_close(socket)
  end

  def close(_), do: :ok

  @doc """
  Requests one metadata piece (BEP 9 § request) and waits for a matching data or reject reply.

  Unrelated extended messages are ignored per BEP 9 (unrecognized IDs) and BEP 10.
  """
  @spec request_piece(t(), non_neg_integer()) ::
          {:ok, binary(), pos_integer()} | {:reject, non_neg_integer()} | {:error, term()}
  def request_piece(%__MODULE__{} = conn, piece_index) do
    ut_id = Peer.LTEP.Session.peer_extension_id(conn.ltep, @ut_metadata)

    if is_integer(ut_id) and ut_id > 0 do
      payload = Magnet.UtMetadata.encode_request(piece_index)

      wire = Peer.LTEP.extended_message_wire(ut_id, payload)

      with {:ok, conn} <- ensure_ready_for_ut_metadata(conn),
           :ok <- io_send(conn, wire) do
        local_ut = Peer.LTEP.Session.local_extension_id(conn.ltep, @ut_metadata)

        Logger.info(
          "[magnet_ut] wire_tx transport=#{conn.transport} endpoint=#{endpoint(conn)} piece=#{piece_index} peer_ut_id=#{ut_id} local_ut_id=#{inspect(local_ut)} bytes=#{wire_hex(wire)}"
        )

        recv_ut_metadata_response(conn, piece_index)
      else
        {:error, :choked} ->
          Logger.info(
            "[magnet_ut] choked_send transport=#{conn.transport} endpoint=#{endpoint(conn)} piece=#{piece_index}"
          )

          with :ok <- io_send(conn, wire) do
            recv_ut_metadata_response(conn, piece_index)
          end

        {:error, _} = error -> error
        other -> {:error, other}
      end
    else
      {:error, :no_ut_metadata}
    end
  end

  @spec fetch_metadata(Peer.t(), Torrent.hash()) :: {:ok, map(), binary()} | {:error, term()}
  def fetch_metadata(peer, hash) do
    with {:ok, conn} <- open(peer, hash),
         result <- download_all_pieces(conn, hash),
         :ok <- close(conn) do
      result
    end
  end

  @spec download_all_pieces(t(), Torrent.hash()) :: {:ok, map(), binary()} | {:error, term()}
  defp download_all_pieces(%__MODULE__{metadata_size: nil} = conn, hash) do
    # Learn total size from the first data message (BEP 9 § data includes total_size).
    case request_piece(conn, 0) do
      {:ok, data, total_size} ->
        pieces = %{0 => data}
        fetch_remaining(conn, hash, total_size, pieces, 1)

      {:reject, _} ->
        {:error, :metadata_rejected}

      {:error, _} = error ->
        error
    end
  end

  defp download_all_pieces(%__MODULE__{metadata_size: total_size} = conn, hash) do
    fetch_remaining(conn, hash, total_size, %{}, 0)
  end

  @spec fetch_remaining(
          t(),
          Torrent.hash(),
          pos_integer(),
          %{non_neg_integer() => binary()},
          non_neg_integer()
        ) ::
          {:ok, map(), binary()} | {:error, term()}
  defp fetch_remaining(conn, hash, total_size, pieces, next_index) do
    count = Magnet.UtMetadata.piece_count(total_size)

    if map_size(pieces) == count do
      with {:ok, blob} <- Magnet.UtMetadata.assemble_pieces(pieces, total_size) do
        Magnet.UtMetadata.decode_and_verify_info(blob, hash)
      end
    else
      case Map.get(pieces, next_index) do
        nil ->
          case request_piece(conn, next_index) do
            {:ok, data, ^total_size} ->
              fetch_remaining(
                pulse_swarm_conn(conn),
                hash,
                total_size,
                Map.put(pieces, next_index, data),
                next_index + 1
              )

            {:ok, _data, other_size} ->
              {:error, {:metadata_size_mismatch, other_size, total_size}}

            {:reject, _} ->
              {:error, :metadata_rejected}

            {:error, _} = error ->
              error
          end

        _ ->
          fetch_remaining(conn, hash, total_size, pieces, next_index + 1)
      end
    end
  end

  @spec family_for_ip(:inet.ip_address()) :: :inet | :inet6
  defp family_for_ip({_, _, _, _}), do: :inet
  defp family_for_ip({_, _, _, _, _, _, _, _}), do: :inet6

  @spec handshake_exchange(t() | Peer.Transport.socket(), Torrent.hash()) :: :ok | {:error, term()}
  defp handshake_exchange(%__MODULE__{} = conn, hash), do: handshake_exchange(conn.socket, hash)

  defp handshake_exchange(socket, hash) do
    with :ok <- io_send_raw(socket, outbound_handshake(hash)),
         {:ok, reserved} <- recv_handshake(socket, hash),
         true <- Peer.LTEP.extension_protocol?(reserved) do
      :ok
    else
      false -> {:error, :no_extension_protocol}
      other -> other
    end
  end

  @spec io_send_raw(Peer.Transport.socket() | nil, iodata()) :: :ok | {:error, term()}
  defp io_send_raw(nil, _data), do: {:error, :closed}
  defp io_send_raw(socket, data), do: Peer.Transport.send(socket, data)

  @spec io_send(t(), iodata()) :: :ok | {:error, term()}
  defp io_send(%__MODULE__{peer_key: key}, data) when not is_nil(key),
    do: Peer.Sender.socket_send_raw(key, data)

  defp io_send(%__MODULE__{socket: socket}, data), do: io_send_raw(socket, data)

  @spec io_recv(t() | Peer.Transport.socket(), non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  defp io_recv(%__MODULE__{peer_key: key}, len, timeout) when not is_nil(key),
    do: Peer.Sender.socket_recv(key, len, timeout)

  defp io_recv(%__MODULE__{socket: socket}, len, timeout), do: io_recv(socket, len, timeout)

  defp io_recv(nil, _, _), do: {:error, :closed}

  defp io_recv(socket, len, timeout) when not is_nil(socket),
    do: Peer.Transport.recv(socket, len, timeout)

  @spec outbound_handshake(Torrent.hash()) :: iodata()
  defp outbound_handshake(hash) do
    [@pstrlen, @pstr, @reserved, hash, Peer.id()]
  end

  @spec recv_handshake(Peer.Transport.socket(), Torrent.hash()) ::
          {:ok, Peer.reserved()} | {:error, term()}
  defp recv_handshake(socket, expected_hash) do
    case io_recv(socket, @handshake_length, @recv_timeout) do
      {:ok,
       <<@pstrlen, @pstr, reserved::bytes-size(8), hash::bytes-size(20),
         _peer_id::bytes-size(20)>>} ->
        if hash == expected_hash do
          {:ok, reserved}
        else
          {:error, :info_hash_mismatch}
        end

      {:ok, _} ->
        {:error, :invalid_handshake}

      {:error, _} = error ->
        error
    end
  end

  @spec ltep_handshake_exchange(Peer.Transport.socket()) ::
          {:ok, Peer.LTEP.Session.t()} | {:error, term()}
  defp ltep_handshake_exchange(socket) do
    session = Peer.LTEP.Session.new()
    Peer.LTEP.handshake_exchange(socket, session)
  end

  # BEP 3: metadata leechers send interested (no have_none — some peers choke permanently otherwise).
  @spec send_interested(t() | Peer.Transport.socket()) :: :ok | {:error, term()}
  defp send_interested(%__MODULE__{} = conn), do: send_interested(conn.socket)

  defp send_interested(socket) do
    io_send_raw(socket, <<0, 0, 0, 1, @interested_id>>)
  end

  @spec ensure_ready_for_ut_metadata(t()) :: {:ok, t()} | {:error, term()}
  defp ensure_ready_for_ut_metadata(%__MODULE__{unchoked?: true} = conn), do: {:ok, conn}

  # BEP 9: ut_metadata exchange does not require an unchoke on the swarm path.
  defp ensure_ready_for_ut_metadata(%__MODULE__{transport: :swarm} = conn), do: {:ok, conn}

  defp ensure_ready_for_ut_metadata(%__MODULE__{} = conn) do
    deadline = System.monotonic_time(:millisecond) + @unchoke_wait_ms

    case drain_until(deadline, conn, :unchoke) do
      {:ok, conn} -> {:ok, conn}
      {:error, :choked} -> {:error, :choked}
      {:error, _} = error -> error
    end
  end

  @spec pulse_swarm_conn(t()) :: t()
  defp pulse_swarm_conn(%__MODULE__{} = conn) do
    _ = maybe_send_keepalive(conn)
    conn
  end

  # Drain early BEP 3 traffic (have_all, port, choke/unchoke cycles) before ut_metadata.
  @spec prime_inbound_messages(t()) :: {:ok, t()} | {:error, term()}
  defp prime_inbound_messages(%__MODULE__{} = conn) when @prime_inbound_ms <= 0, do: {:ok, conn}

  defp prime_inbound_messages(%__MODULE__{} = conn) when @prime_inbound_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + @prime_inbound_ms

    case drain_until(deadline, conn, :sync) do
      {:ok, primed} -> {:ok, primed}
      {:error, _} = error -> error
    end
  end

  @spec drain_until(integer(), t(), :unchoke | :ut_metadata | :sync) ::
          {:ok, t()} | {:error, term()} | {:ut_metadata, t(), binary()}
  defp drain_until(deadline, conn, mode) do
    now = System.monotonic_time(:millisecond)
    if now >= deadline, do: timeout_error(mode, conn)

    remaining = deadline - now

    with {:continue, conn} <- maybe_return_stable_unchoke(mode, conn) do
      poll_timeout =
        if mode == :ut_metadata,
          do: min(remaining, @wire_body_timeout_ms),
          else: min(remaining, 1_000)

      case recv_wire_frame(conn, poll_timeout) do
        {:ok, :keepalive} ->
          drain_until(deadline, conn, mode)

        {:ok, {:standard, @unchoke_id, _payload} = frame} ->
          log_ut_metadata_wire_rx(conn, frame, nil, nil, nil, mode)
          conn = track_unchoke(conn, true)
          drain_until(deadline, conn, mode)

        {:ok, {:standard, @choke_id, _payload} = frame} ->
          log_ut_metadata_wire_rx(conn, frame, nil, nil, nil, mode)
          drain_until(deadline, track_unchoke(conn, false), mode)

        {:ok, {:standard, _message_id, _payload} = frame} ->
          log_ut_metadata_wire_rx(conn, frame, nil, nil, nil, mode)
          drain_until(deadline, conn, mode)

        {:ok, {:extended, @ltep_handshake_id, payload}} ->
          conn = %{conn | ltep: Peer.LTEP.merge_handshake(conn.ltep, payload)}
          drain_until(deadline, conn, mode)

        {:ok, {:extended, ext_id, payload}} ->
          peer_ut_id = Peer.LTEP.Session.peer_extension_id(conn.ltep, @ut_metadata)
          local_ut_id = Peer.LTEP.Session.local_extension_id(conn.ltep, @ut_metadata)

          if mode == :ut_metadata do
            log_ut_metadata_wire_rx(conn, ext_id, payload, local_ut_id, peer_ut_id)
          end

          if mode == :ut_metadata and is_integer(local_ut_id) and ext_id == local_ut_id do
            {:ut_metadata, conn, payload}
          else
            drain_until(deadline, conn, mode)
          end

        {:error, :timeout} ->
          _ = maybe_send_keepalive(conn)
          drain_until(deadline, conn, mode)

        {:error, reason} ->
          {:error, normalize_peer_error(reason)}

        other ->
          other
      end
    end
  end

  @spec normalize_peer_error(term()) :: term()
  defp normalize_peer_error(:noproc), do: :peer_died
  defp normalize_peer_error(:closed), do: :peer_died
  defp normalize_peer_error({:noproc, _}), do: :peer_died
  defp normalize_peer_error(reason), do: reason

  # BEP 3: libtorrent seeders may unchoke, choke, then unchoke again before metadata.
  @spec maybe_return_stable_unchoke(:unchoke | :ut_metadata | :sync, t()) ::
          {:continue, t()} | {:ok, t()}
  defp maybe_return_stable_unchoke(:unchoke, %{unchoked?: true, unchoke_since: since} = conn)
       when is_integer(since) do
    if System.monotonic_time(:millisecond) - since >= @unchoke_stable_ms,
      do: {:ok, conn},
      else: {:continue, conn}
  end

  defp maybe_return_stable_unchoke(:sync, conn), do: {:continue, conn}
  defp maybe_return_stable_unchoke(_, conn), do: {:continue, conn}

  @spec maybe_send_keepalive(t()) :: :ok
  defp maybe_send_keepalive(%__MODULE__{transport: :swarm, peer_key: key}) when not is_nil(key) do
    _ = Peer.Sender.socket_send_raw(key, <<0, 0, 0, 0>>)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp maybe_send_keepalive(_conn), do: :ok

  @spec track_unchoke(t(), boolean()) :: t()
  defp track_unchoke(conn, true) do
    now = System.monotonic_time(:millisecond)
    %{conn | unchoked?: true, unchoke_since: now}
  end

  defp track_unchoke(conn, false) do
    %{conn | unchoked?: false, unchoke_since: nil}
  end

  defp timeout_error(:unchoke, %{unchoked?: true, unchoke_since: since} = conn)
       when is_integer(since) do
    if System.monotonic_time(:millisecond) - since >= @unchoke_stable_ms,
      do: {:ok, conn},
      else: {:error, :choked}
  end

  defp timeout_error(:unchoke, _conn), do: {:error, :choked}
  defp timeout_error(:sync, conn), do: {:ok, conn}
  defp timeout_error(:ut_metadata, _conn), do: {:error, :timeout}

  @type wire_frame ::
          :keepalive
          | {:standard, pos_integer(), binary()}
          | {:extended, non_neg_integer(), binary()}

  @spec recv_wire_frame(t(), non_neg_integer()) :: {:ok, wire_frame()} | {:error, term()}
  defp recv_wire_frame(%__MODULE__{} = conn, timeout) do
    with {:ok, <<length::32>>} <- io_recv(conn, 4, timeout),
         true <- length <= @max_wire_message_length do
      body_timeout = wire_body_timeout(length, timeout)

      cond do
        length == 0 ->
          {:ok, :keepalive}

        length >= 2 ->
          case io_recv(conn, length, body_timeout) do
            {:ok, message} ->
              case message do
                <<message_id, rest::binary>> when message_id == @ltep_message_id ->
                  case rest do
                    <<extended_id, payload::binary>> ->
                      {:ok, {:extended, extended_id, payload}}

                    _ ->
                      {:error, :invalid_message}
                  end

                <<message_id, rest::binary>> ->
                  {:ok, {:standard, message_id, rest}}
              end

            {:error, _} = error ->
              error
          end

        true ->
          with {:ok, <<message_id>>} <- io_recv(conn, length, body_timeout) do
            {:ok, {:standard, message_id, <<>>}}
          end
      end
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  end

  @spec wire_body_timeout(non_neg_integer(), non_neg_integer()) :: pos_integer()
  defp wire_body_timeout(0, timeout), do: timeout

  defp wire_body_timeout(length, timeout) when length > 0 do
    max(timeout, min(@wire_body_timeout_ms, max(length, 1_000)))
  end

  @spec recv_ut_metadata_response(t(), non_neg_integer()) ::
          {:ok, binary(), pos_integer()} | {:reject, non_neg_integer()} | {:error, term()}
  defp recv_ut_metadata_response(%__MODULE__{} = conn, expected_piece) do
    deadline = System.monotonic_time(:millisecond) + @recv_timeout
    recv_ut_metadata_loop(conn, expected_piece, deadline)
  end

  @spec recv_ut_metadata_loop(t(), non_neg_integer(), integer()) ::
          {:ok, binary(), pos_integer()} | {:reject, non_neg_integer()} | {:error, term()}
  defp recv_ut_metadata_loop(conn, expected_piece, deadline) do
    case drain_until(deadline, conn, :ut_metadata) do
      {:ut_metadata, conn, payload} ->
        handle_ut_metadata_payload(conn, expected_piece, payload, deadline)

      {:ok, _conn} ->
        log_recv_timeout(conn, expected_piece)
        {:error, :timeout}

      {:error, :timeout} ->
        log_recv_timeout(conn, expected_piece)
        {:error, :timeout}

      {:error, _} = error ->
        error
    end
  end

  @spec handle_ut_metadata_payload(t(), non_neg_integer(), binary(), integer()) ::
          {:ok, binary(), pos_integer()} | {:reject, non_neg_integer()} | {:error, term()}
  defp handle_ut_metadata_payload(conn, expected_piece, payload, deadline) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:data, data_kw}} ->
        piece = Keyword.fetch!(data_kw, :piece)
        total_size = Keyword.fetch!(data_kw, :total_size)
        data = Keyword.fetch!(data_kw, :data)

        cond do
          piece != expected_piece ->
            recv_ut_metadata_loop(conn, expected_piece, deadline)

          Magnet.UtMetadata.piece_byte_size(total_size, expected_piece) == byte_size(data) ->
            Logger.info(
              "[magnet_ut] piece ok endpoint=#{endpoint(conn)} piece=#{expected_piece} bytes=#{byte_size(data)} total_size=#{total_size}"
            )

            {:ok, data, total_size}

          true ->
            Logger.warning(
              "[magnet_ut] invalid_piece_size endpoint=#{endpoint(conn)} piece=#{expected_piece} expected=#{Magnet.UtMetadata.piece_byte_size(total_size, expected_piece)} got=#{byte_size(data)} total_size=#{total_size}"
            )

            {:error, :invalid_piece_size}
        end

      {:ok, {:reject, piece: ^expected_piece}} ->
        Logger.info("[magnet_ut] reject endpoint=#{endpoint(conn)} piece=#{expected_piece}")
        {:reject, expected_piece}

      {:ok, {:reject, piece: _other}} ->
        recv_ut_metadata_loop(conn, expected_piece, deadline)

      {:ok, {:request, _}} ->
        recv_ut_metadata_loop(conn, expected_piece, deadline)

      {:error, reason} ->
        Logger.warning(
          "[magnet_ut] decode_fail endpoint=#{endpoint(conn)} piece=#{expected_piece} reason=#{inspect(reason)} payload=#{wire_hex(payload, 96)}"
        )

        recv_ut_metadata_loop(conn, expected_piece, deadline)
    end
  end

  @spec log_ut_metadata_wire_rx(t(), term(), term(), term(), term(), :unchoke | :ut_metadata | :sync) ::
          :ok
  defp log_ut_metadata_wire_rx(conn, frame, ext_id, local_ut_id, peer_ut_id, mode \\ :ut_metadata)

  defp log_ut_metadata_wire_rx(_conn, _frame, _ext_id, _local_ut_id, _peer_ut_id, mode)
       when mode != :ut_metadata,
       do: :ok

  defp log_ut_metadata_wire_rx(conn, {:standard, message_id, payload}, _, _, _, _) do
    Logger.info(
      "[magnet_ut] wire_rx endpoint=#{endpoint(conn)} standard_id=#{message_id} payload_len=#{byte_size(payload)}"
    )
  end

  defp log_ut_metadata_wire_rx(conn, ext_id, payload, local_ut_id, peer_ut_id, _) do
    Logger.info(
      "[magnet_ut] wire_rx endpoint=#{endpoint(conn)} ext_id=#{ext_id} local_ut_id=#{inspect(local_ut_id)} peer_ut_id=#{inspect(peer_ut_id)} payload_len=#{byte_size(payload)} payload_prefix=#{wire_hex(payload, 64)}"
    )
  end

  @spec log_recv_timeout(t(), non_neg_integer()) :: :ok
  defp log_recv_timeout(conn, expected_piece) do
    Logger.warning(
      "[magnet_ut] recv_timeout endpoint=#{endpoint(conn)} piece=#{expected_piece}"
    )
  end

  @spec wire_hex(binary(), pos_integer()) :: String.t()
  defp wire_hex(data, max \\ 128)

  defp wire_hex(data, max) when is_binary(data) do
    data
    |> binary_part(0, min(byte_size(data), max))
    |> Base.encode16(case: :lower)
  end

  defp endpoint(%__MODULE__{transport: :swarm, peer_key: key}) when not is_nil(key),
    do: "peer=#{Peer.log_key(key)}"

  defp endpoint(%__MODULE__{peer: %Peer{ip: ip, port: port}}), do: inspect({ip, port})
  defp endpoint(_), do: "?"
end

defmodule Magnet.Connection do
  @moduledoc false

  require Logger

  alias Peer.LTEP.{Extensions, Session}
  alias Peer.UtPex.InboundRate

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

  defp magnet_cfg(key, default) do
    Application.get_env(:elixir_torrent, :magnet_connection, [])
    |> Keyword.get(key, default)
  end

  defp recv_timeout_ms, do: magnet_cfg(:recv_timeout_ms, @recv_timeout)
  defp unchoke_wait_ms, do: magnet_cfg(:unchoke_wait_ms, @unchoke_wait_ms)

  defp controller_unchoke_poll_ms,
    do: magnet_cfg(:controller_unchoke_poll_ms, @controller_unchoke_poll_ms)

  defp unchoke_stable_ms, do: magnet_cfg(:unchoke_stable_ms, @unchoke_stable_ms)

  defstruct [
    :socket,
    :peer_key,
    :ltep,
    :metadata_size,
    :hash,
    :pex_source,
    peer: nil,
    transport: :tcp,
    unchoked?: false,
    unchoke_since: nil,
    pex_inbound: %{initial?: true, rate: InboundRate.initial()}
  ]

  @type transport :: :tcp | :utp | :swarm

  @type t :: %__MODULE__{
          socket: Peer.Transport.socket() | nil,
          peer_key: Peer.key() | nil,
          ltep: Session.t(),
          metadata_size: pos_integer() | nil,
          hash: Torrent.hash() | nil,
          pex_source: Peer.id() | nil,
          peer: Peer.t() | nil,
          transport: transport(),
          pex_inbound: %{initial?: boolean(), rate: map()}
        }

  @doc false
  @spec pex_consumer_active?(Torrent.hash()) :: boolean()
  def pex_consumer_active?(hash) when is_binary(hash) and byte_size(hash) == 20 do
    consume_pex_enabled?() and connection_manager_alive?(hash)
  end

  @doc false
  @spec consume_pex_enabled?() :: boolean()
  def consume_pex_enabled? do
    Application.get_env(:elixir_torrent, :magnet_connection, [])
    |> Keyword.get(:consume_pex, true)
  end

  @doc false
  @spec route_inbound_pex_for_test(t(), binary()) :: t()
  def route_inbound_pex_for_test(%__MODULE__{} = conn, payload) when is_binary(payload) do
    route_inbound_pex(conn, payload)
  end

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
         true <- Session.peer_supports?(info.ltep, @ut_metadata) do
      metadata_size = metadata_size_from_ltep(info.ltep) || info.metadata_size
      now_ms = System.monotonic_time(:millisecond)

      unchoked? = info.unchoked? == true

      conn = %__MODULE__{
        socket: nil,
        peer_key: key,
        ltep: info.ltep,
        metadata_size: metadata_size,
        hash: Peer.key_to_hash(key),
        pex_source: Peer.key_to_id(key),
        transport: :swarm,
        peer: nil,
        unchoked?: unchoked?,
        unchoke_since: if(unchoked?, do: now_ms, else: nil),
        pex_inbound: %{initial?: true, rate: InboundRate.initial()}
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
    # BEP 3 magnet dials use plain :gen_tcp — Peer.Transport.connect/4 would pass
    # a :transport tag through to gen_tcp and raise :badarg on OTP 29+.
    case :gen_tcp.connect(ip, port, opts, @connect_timeout) do
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
    UTP.Dispatcher.connect(ip, port, [], @utp_connect_timeout_ms)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @spec do_open(Peer.Transport.socket(), Peer.t(), Torrent.hash(), transport()) ::
          {:ok, t()} | {:error, term()}
  defp do_open(socket, peer, hash, transport) do
    with {:ok, peer_id} <- handshake_exchange(socket, hash),
         {:ok, ltep} <- ltep_handshake_exchange(socket, hash),
         :ok <- send_interested(socket),
         true <- Session.peer_supports?(ltep, @ut_metadata) do
      metadata_size = metadata_size_from_ltep(ltep)

      log_ltep_ready(peer, ltep, metadata_size, transport)

      prime_inbound_messages(%__MODULE__{
        socket: socket,
        peer_key: nil,
        ltep: ltep,
        metadata_size: metadata_size,
        hash: hash,
        pex_source: peer_id,
        transport: transport,
        peer: peer,
        unchoked?: false,
        unchoke_since: nil,
        pex_inbound: %{initial?: true, rate: InboundRate.initial()}
      })
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
    deadline = System.monotonic_time(:millisecond) + unchoke_wait_ms()
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

      Session.peer_supports?(info.ltep, @ut_metadata) ->
        # BEP 9 peers may omit metadata_size in LTEP; probe piece 0 and
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
        Process.sleep(controller_unchoke_poll_ms())
        do_wait_controller_ready(key, info, deadline)
    end
  catch
    :exit, reason -> {:error, normalize_peer_error(reason)}
  end

  @spec metadata_seeder?(map()) :: boolean()
  defp metadata_seeder?(info), do: info[:seeder?] == true or info.seeder? == true

  defp metadata_size_from_ltep(ltep) do
    case Session.peer_handshake(ltep).metadata_size do
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
    peer_ut = Session.peer_extension_id(ltep, @ut_metadata)
    local_ut = Session.local_extension_id(ltep, @ut_metadata)

    Logger.info(
      "[magnet_ut] handshake ok transport=#{transport} endpoint=#{inspect({ip, port})} peer_ut_id=#{inspect(peer_ut)} local_ut_id=#{inspect(local_ut)} metadata_size=#{inspect(metadata_size)}"
    )
  end

  defp log_ltep_ready_swarm(key, ltep, metadata_size) do
    peer_ut = Session.peer_extension_id(ltep, @ut_metadata)
    local_ut = Session.local_extension_id(ltep, @ut_metadata)

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
    case request_piece_with_conn(conn, piece_index) do
      {:ok, data, total_size, _conn} -> {:ok, data, total_size}
      {:reject, piece, _conn} -> {:reject, piece}
      {:error, _} = error -> error
    end
  end

  @spec request_piece_with_conn(t(), non_neg_integer()) ::
          {:ok, binary(), pos_integer(), t()}
          | {:reject, non_neg_integer(), t()}
          | {:error, term()}
  defp request_piece_with_conn(%__MODULE__{} = conn, piece_index) do
    ut_id = Session.peer_extension_id(conn.ltep, @ut_metadata)

    if is_integer(ut_id) and ut_id > 0 do
      payload = Magnet.UtMetadata.encode_request(piece_index)

      wire = Peer.LTEP.extended_message_wire(ut_id, payload)

      with {:ok, conn} <- ensure_ready_for_ut_metadata(conn),
           :ok <- io_send(conn, wire) do
        local_ut = Session.local_extension_id(conn.ltep, @ut_metadata)

        Logger.info(
          "[magnet_ut] wire_tx transport=#{conn.transport} endpoint=#{endpoint(conn)} piece=#{piece_index} peer_ut_id=#{ut_id} local_ut_id=#{inspect(local_ut)} bytes=#{wire_hex(wire)}"
        )

        recv_ut_metadata_response(conn, piece_index)
      else
        {:error, :choked, conn} ->
          send_choked_piece_request(conn, wire, piece_index)

        {:error, _} = error ->
          error

        other ->
          {:error, other}
      end
    else
      {:error, :no_ut_metadata}
    end
  end

  @spec send_choked_piece_request(t(), iodata(), non_neg_integer()) ::
          {:ok, binary(), pos_integer(), t()}
          | {:reject, non_neg_integer(), t()}
          | {:error, term()}
  defp send_choked_piece_request(conn, wire, piece_index) do
    Logger.info(
      "[magnet_ut] choked_send transport=#{conn.transport} endpoint=#{endpoint(conn)} piece=#{piece_index}"
    )

    with :ok <- io_send(conn, wire) do
      recv_ut_metadata_response(conn, piece_index)
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
    case request_piece_with_conn(conn, 0) do
      {:ok, data, total_size, conn} ->
        pieces = %{0 => data}
        fetch_remaining(conn, hash, total_size, pieces, 1)

      {:reject, _, _conn} ->
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
          fetch_piece_at_index(conn, hash, total_size, pieces, next_index)

        _ ->
          fetch_remaining(conn, hash, total_size, pieces, next_index + 1)
      end
    end
  end

  @spec fetch_piece_at_index(
          t(),
          Torrent.hash(),
          pos_integer(),
          %{non_neg_integer() => binary()},
          non_neg_integer()
        ) ::
          {:ok, map(), binary()} | {:error, term()}
  defp fetch_piece_at_index(conn, hash, total_size, pieces, next_index) do
    case request_piece_with_conn(conn, next_index) do
      {:ok, data, ^total_size, conn} ->
        fetch_remaining(
          pulse_swarm_conn(conn),
          hash,
          total_size,
          Map.put(pieces, next_index, data),
          next_index + 1
        )

      {:ok, _data, other_size, _conn} ->
        {:error, {:metadata_size_mismatch, other_size, total_size}}

      {:reject, _, _conn} ->
        {:error, :metadata_rejected}

      {:error, _} = error ->
        error
    end
  end

  @spec family_for_ip(:inet.ip_address()) :: :inet | :inet6
  defp family_for_ip({_, _, _, _}), do: :inet
  defp family_for_ip({_, _, _, _, _, _, _, _}), do: :inet6

  @spec handshake_exchange(Peer.Transport.socket(), Torrent.hash()) ::
          {:ok, Peer.id()} | {:error, term()}
  defp handshake_exchange(socket, hash) do
    with :ok <- io_send_raw(socket, outbound_handshake(hash)),
         {:ok, reserved, peer_id} <- recv_handshake(socket, hash),
         true <- Peer.LTEP.extension_protocol?(reserved) do
      {:ok, peer_id}
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
          {:ok, Peer.reserved(), Peer.id()} | {:error, term()}
  defp recv_handshake(socket, expected_hash) do
    case io_recv(socket, @handshake_length, recv_timeout_ms()) do
      {:ok,
       <<@pstrlen, @pstr, reserved::bytes-size(8), hash::bytes-size(20), peer_id::bytes-size(20)>>} ->
        if hash == expected_hash do
          {:ok, reserved, peer_id}
        else
          {:error, :info_hash_mismatch}
        end

      {:ok, _} ->
        {:error, :invalid_handshake}

      {:error, _} = error ->
        error
    end
  end

  @spec ltep_handshake_exchange(Peer.Transport.socket(), Torrent.hash()) ::
          {:ok, Session.t()} | {:error, term()}
  defp ltep_handshake_exchange(socket, hash) do
    extensions = Extensions.for_magnet(hash)
    session = Session.new(extensions)
    Peer.LTEP.handshake_exchange(socket, session)
  end

  # BEP 3: metadata leechers send interested (no have_none — some peers choke permanently otherwise).
  @spec send_interested(t() | Peer.Transport.socket()) :: :ok | {:error, term()}
  defp send_interested(%__MODULE__{} = conn), do: send_interested(conn.socket)

  defp send_interested(socket) do
    io_send_raw(socket, <<0, 0, 0, 1, @interested_id>>)
  end

  @spec ensure_ready_for_ut_metadata(t()) ::
          {:ok, t()} | {:error, term()} | {:error, :choked, t()}
  defp ensure_ready_for_ut_metadata(%__MODULE__{unchoked?: true} = conn), do: {:ok, conn}

  # BEP 9: ut_metadata exchange does not require an unchoke on the swarm path.
  defp ensure_ready_for_ut_metadata(%__MODULE__{transport: :swarm} = conn), do: {:ok, conn}

  defp ensure_ready_for_ut_metadata(%__MODULE__{} = conn) do
    deadline = System.monotonic_time(:millisecond) + unchoke_wait_ms()

    case drain_until(deadline, conn, :unchoke) do
      {:ok, conn} -> {:ok, conn}
      {:error, :choked, conn} -> {:error, :choked, conn}
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
          {:ok, t()}
          | {:error, term()}
          | {:error, :choked, t()}
          | {:ut_metadata, t(), binary()}
  defp drain_until(deadline, conn, mode) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      timeout_error(mode, conn)
    else
      drain_before_deadline(deadline, conn, mode, deadline - now)
    end
  end

  @spec drain_before_deadline(integer(), t(), :unchoke | :ut_metadata | :sync, pos_integer()) ::
          {:ok, t()}
          | {:error, term()}
          | {:error, :choked, t()}
          | {:ut_metadata, t(), binary()}
  defp drain_before_deadline(deadline, conn, mode, remaining) do
    with {:continue, conn} <- maybe_return_stable_unchoke(mode, conn) do
      poll_timeout = drain_poll_timeout(mode, remaining)

      case recv_wire_frame(conn, poll_timeout) do
        {:ok, frame} ->
          drain_after_frame(deadline, conn, mode, frame)

        {:error, :timeout} ->
          _ = maybe_send_keepalive(conn)
          drain_until(deadline, conn, mode)

        {:error, reason} ->
          {:error, normalize_peer_error(reason)}
      end
    end
  end

  @spec drain_poll_timeout(:unchoke | :ut_metadata | :sync, non_neg_integer()) :: pos_integer()
  defp drain_poll_timeout(:ut_metadata, remaining),
    do: min(remaining, @wire_body_timeout_ms)

  defp drain_poll_timeout(_mode, remaining), do: min(remaining, 1_000)

  @spec drain_after_frame(integer(), t(), :unchoke | :ut_metadata | :sync, wire_frame()) ::
          {:ok, t()}
          | {:error, term()}
          | {:error, :choked, t()}
          | {:ut_metadata, t(), binary()}
  defp drain_after_frame(deadline, conn, mode, :keepalive) do
    drain_until(deadline, conn, mode)
  end

  defp drain_after_frame(deadline, conn, mode, {:standard, @unchoke_id, _payload} = frame) do
    log_ut_metadata_wire_rx(conn, frame, nil, nil, nil, mode)
    drain_until(deadline, track_unchoke(conn, true), mode)
  end

  defp drain_after_frame(deadline, conn, mode, {:standard, @choke_id, _payload} = frame) do
    log_ut_metadata_wire_rx(conn, frame, nil, nil, nil, mode)
    drain_until(deadline, track_unchoke(conn, false), mode)
  end

  defp drain_after_frame(deadline, conn, mode, {:standard, _message_id, _payload} = frame) do
    log_ut_metadata_wire_rx(conn, frame, nil, nil, nil, mode)
    drain_until(deadline, conn, mode)
  end

  defp drain_after_frame(deadline, conn, mode, {:extended, @ltep_handshake_id, payload}) do
    conn = %{conn | ltep: Peer.LTEP.merge_handshake(conn.ltep, payload)}
    drain_until(deadline, conn, mode)
  end

  defp drain_after_frame(deadline, conn, mode, {:extended, ext_id, payload}) do
    conn = ingest_negotiated_ut_pex(conn, ext_id, payload)
    drain_after_extended(deadline, conn, mode, ext_id, payload)
  end

  @spec drain_after_extended(
          integer(),
          t(),
          :unchoke | :ut_metadata | :sync,
          non_neg_integer(),
          binary()
        ) ::
          {:ok, t()}
          | {:error, term()}
          | {:error, :choked, t()}
          | {:ut_metadata, t(), binary()}
  defp drain_after_extended(deadline, conn, mode, ext_id, payload) do
    peer_ut_id = Session.peer_extension_id(conn.ltep, @ut_metadata)
    local_ut_id = Session.local_extension_id(conn.ltep, @ut_metadata)

    if mode == :ut_metadata do
      log_ut_metadata_wire_rx(conn, ext_id, payload, local_ut_id, peer_ut_id)
    end

    if mode == :ut_metadata and is_integer(local_ut_id) and ext_id == local_ut_id do
      {:ut_metadata, conn, payload}
    else
      drain_until(deadline, conn, mode)
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
    if System.monotonic_time(:millisecond) - since >= unchoke_stable_ms(),
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
    if System.monotonic_time(:millisecond) - since >= unchoke_stable_ms(),
      do: {:ok, conn},
      else: {:error, :choked, conn}
  end

  defp timeout_error(:unchoke, conn), do: {:error, :choked, conn}
  defp timeout_error(:sync, conn), do: {:ok, conn}
  defp timeout_error(:ut_metadata, _conn), do: {:error, :timeout}

  @type wire_frame ::
          :keepalive
          | {:standard, pos_integer(), binary()}
          | {:extended, non_neg_integer(), binary()}

  @spec recv_wire_frame(t(), non_neg_integer()) :: {:ok, wire_frame()} | {:error, term()}
  defp recv_wire_frame(%__MODULE__{} = conn, timeout) do
    with {:ok, <<length::32>>} <- io_recv(conn, 4, timeout),
         true <- length <= @max_wire_message_length,
         {:ok, message} <- recv_wire_body(conn, length, timeout) do
      decode_wire_frame(length, message)
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  end

  @spec recv_wire_body(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp recv_wire_body(_conn, 0, _timeout), do: {:ok, <<>>}

  defp recv_wire_body(conn, length, timeout) when length >= 2 do
    io_recv(conn, length, wire_body_timeout(length, timeout))
  end

  defp recv_wire_body(conn, length, timeout) when length == 1 do
    io_recv(conn, length, wire_body_timeout(length, timeout))
  end

  @spec decode_wire_frame(non_neg_integer(), binary()) :: {:ok, wire_frame()} | {:error, term()}
  defp decode_wire_frame(0, _), do: {:ok, :keepalive}

  defp decode_wire_frame(_length, <<message_id, rest::binary>>)
       when message_id == @ltep_message_id do
    case rest do
      <<extended_id, payload::binary>> -> {:ok, {:extended, extended_id, payload}}
      _ -> {:error, :invalid_message}
    end
  end

  defp decode_wire_frame(_length, <<message_id, rest::binary>>),
    do: {:ok, {:standard, message_id, rest}}

  @spec wire_body_timeout(non_neg_integer(), non_neg_integer()) :: pos_integer()
  defp wire_body_timeout(0, timeout), do: timeout

  defp wire_body_timeout(length, timeout) when length > 0 do
    max(timeout, min(@wire_body_timeout_ms, max(length, 1_000)))
  end

  @spec recv_ut_metadata_response(t(), non_neg_integer()) ::
          {:ok, binary(), pos_integer(), t()}
          | {:reject, non_neg_integer(), t()}
          | {:error, term()}
  defp recv_ut_metadata_response(%__MODULE__{} = conn, expected_piece) do
    deadline = System.monotonic_time(:millisecond) + recv_timeout_ms()
    recv_ut_metadata_loop(conn, expected_piece, deadline)
  end

  @spec recv_ut_metadata_loop(t(), non_neg_integer(), integer()) ::
          {:ok, binary(), pos_integer(), t()}
          | {:reject, non_neg_integer(), t()}
          | {:error, term()}
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
          {:ok, binary(), pos_integer(), t()}
          | {:reject, non_neg_integer(), t()}
          | {:error, term()}
  defp handle_ut_metadata_payload(conn, expected_piece, payload, deadline) do
    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:data, data_kw}} ->
        handle_ut_metadata_data(conn, expected_piece, deadline, data_kw)

      {:ok, {:reject, piece: ^expected_piece}} ->
        Logger.info("[magnet_ut] reject endpoint=#{endpoint(conn)} piece=#{expected_piece}")
        {:reject, expected_piece, conn}

      {:ok, {:reject, piece: _other}} ->
        recv_ut_metadata_loop(conn, expected_piece, deadline)

      {:ok, {:request, _}} ->
        recv_ut_metadata_loop(conn, expected_piece, deadline)

      {:error, :piece_too_large} ->
        log_invalid_piece_size(conn, expected_piece, :piece_too_large)
        {:error, :invalid_piece_size}

      {:error, reason} ->
        Logger.warning(
          "[magnet_ut] decode_fail endpoint=#{endpoint(conn)} piece=#{expected_piece} reason=#{inspect(reason)} payload=#{wire_hex(payload, 96)}"
        )

        recv_ut_metadata_loop(conn, expected_piece, deadline)
    end
  end

  @spec handle_ut_metadata_data(t(), non_neg_integer(), integer(), keyword()) ::
          {:ok, binary(), pos_integer(), t()}
          | {:reject, non_neg_integer(), t()}
          | {:error, term()}
  defp handle_ut_metadata_data(conn, expected_piece, deadline, data_kw) do
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

        {:ok, data, total_size, conn}

      true ->
        log_invalid_piece_size(conn, expected_piece, :size_mismatch, total_size, data)
        {:error, :invalid_piece_size}
    end
  end

  @spec log_invalid_piece_size(t(), non_neg_integer(), :piece_too_large) :: :ok
  defp log_invalid_piece_size(conn, expected_piece, :piece_too_large) do
    Logger.warning(
      "[magnet_ut] invalid_piece_size endpoint=#{endpoint(conn)} piece=#{expected_piece} reason=piece_too_large"
    )
  end

  @spec log_invalid_piece_size(t(), non_neg_integer(), :size_mismatch, pos_integer(), binary()) ::
          :ok
  defp log_invalid_piece_size(conn, expected_piece, :size_mismatch, total_size, data) do
    Logger.warning(
      "[magnet_ut] invalid_piece_size endpoint=#{endpoint(conn)} piece=#{expected_piece} expected=#{Magnet.UtMetadata.piece_byte_size(total_size, expected_piece)} got=#{byte_size(data)} total_size=#{total_size}"
    )
  end

  @spec log_ut_metadata_wire_rx(
          t(),
          term(),
          term(),
          term(),
          term(),
          :unchoke | :ut_metadata | :sync
        ) ::
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
    Logger.warning("[magnet_ut] recv_timeout endpoint=#{endpoint(conn)} piece=#{expected_piece}")
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

  @spec connection_manager_alive?(Torrent.hash()) :: boolean()
  defp connection_manager_alive?(hash) do
    case GenServer.whereis({:via, Registry, {Registry, {hash, Peer.ConnectionManager}}}) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @spec pex_routing_enabled?(t()) :: boolean()
  defp pex_routing_enabled?(%__MODULE__{hash: hash, pex_source: src})
       when is_binary(hash) and byte_size(hash) == 20 and is_binary(src) and byte_size(src) == 20 do
    Peer.UtPex.allowed?(hash) and pex_consumer_active?(hash)
  end

  defp pex_routing_enabled?(_), do: false

  @spec ingest_negotiated_ut_pex(t(), non_neg_integer(), binary()) :: t()
  defp ingest_negotiated_ut_pex(%__MODULE__{} = conn, ext_id, payload) do
    local_pex_id = Session.local_extension_id(conn.ltep, Peer.UtPex.extension_name())

    if pex_routing_enabled?(conn) and is_integer(local_pex_id) and ext_id == local_pex_id do
      route_inbound_pex(conn, payload)
    else
      conn
    end
  end

  @spec route_inbound_pex(t(), binary()) :: t()
  defp route_inbound_pex(%__MODULE__{} = conn, payload) when is_binary(payload) do
    now_ms = System.monotonic_time(:millisecond)

    inbound =
      Map.get(conn, :pex_inbound, %{initial?: true, rate: InboundRate.initial()})

    rate = Map.get(inbound, :rate, InboundRate.initial())

    case InboundRate.gate(rate, now_ms) do
      {:reject, rate} ->
        %{conn | pex_inbound: %{inbound | rate: rate}}

      {:allow, rate, kind} ->
        initial? = kind == :initial

        _ =
          Peer.UtPex.ingest(conn.hash, payload,
            initial?: initial?,
            pex_source: conn.pex_source
          )

        %{
          conn
          | pex_inbound: %{
              inbound
              | initial?: false,
                rate: rate
            }
        }
    end
  end
end

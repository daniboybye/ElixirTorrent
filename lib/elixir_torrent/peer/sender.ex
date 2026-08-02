defmodule Peer.Sender do
  @moduledoc """
  Per-peer wire I/O GenServer: frames BEP 3 messages and extension payloads on the socket.
  """

  # restart overridden to :temporary in Peer.start_link (auto_shutdown tree).
  use GenServer, restart: :temporary
  use Via
  use Peer.Const

  import Peer.Controller

  require Logger

  @timeout 100_000
  @max_length Torrent.Downloads.piece_max_length()
  # BEP 3 piece: <id=7><index::32><begin::32><block>. The largest block we ever
  # ask a peer for is @max_length (16 KiB) — that is the same source of truth the
  # inbound `request` bound-check below and Peer.Controller.valid_piece_block?/4
  # use — so a longer `piece` frame can never be a reply to a request we made.
  @max_piece_message_size 1 + 4 + 4 + @max_length
  # BEP 3 bitfield: <id=5><ceil(pieces_count / 8) bytes>. The exact per-torrent
  # bound needs pieces_count, which is not reachable here (see take_message/1), so
  # bound it by the largest piece count the reference implementation will even
  # load: libtorrent's load_torrent_limits::max_pieces / settings_pack
  # ::max_piece_count default of 0x200000 pieces, i.e. a 256 KiB bitfield.
  @max_bitfield_pieces 0x200000
  @max_bitfield_message_size 1 + Torrent.Bitfield.expected_byte_size(@max_bitfield_pieces)
  @max_hash_header_message_size 1 + Peer.HashWire.header_size()
  @max_hashes_message_size Peer.HashWire.max_hashes_message_size()
  @ut_metadata_local_id Magnet.UtMetadata.Extension.local_id()
  @max_extended_message_size Peer.LTEP.max_message_size()
  # Length includes the top-level wire id and LTEP extension id.
  @max_ut_metadata_message_size 2 + Magnet.UtMetadata.max_message_payload_size()
  # Global recv-buffer ceiling for ONE wire frame, independent of its id. Every
  # BEP 3 frame is <<len::32, id, body>> with a fully attacker-controlled `len`, so
  # the framing layer has to judge plausibility from the 4-byte prefix alone —
  # before it accumulates any bytes toward it. The per-id caps below only cover ids
  # we recognise, and they cannot be extended to the rest: BEP 3 forward-compat
  # requires unknown ids to be *ignored*, so an unknown id declaring 4 GiB would
  # otherwise reach the generic take_message/1 clause, which resolves only once
  # byte_size(rest) >= len — i.e. one 5-byte frame prefix makes us grow the recv
  # buffer toward 4 GiB. libtorrent bounds it the same way, with a single
  # recv-buffer limit for every message id (settings_pack::max_peer_recv_buffer_size,
  # default 2 MiB) and errors::packet_too_large on the disconnect.
  #
  # 2 MiB is 2x the largest frame we legitimately accept (LTEP's 1 MiB), so this
  # ceiling cannot clip any per-id cap — LTEP 1_048_576, bitfield 262_145, hashes
  # 18_481, ut_metadata 17_410, piece 16_393, hash header 49. Deliberately not
  # *equal* to the LTEP cap: an equal ceiling would start rejecting max-size LTEP
  # frames the moment that cap was raised. The comparison is `>` (never `>=`),
  # matching all six per-id guards — a declared length exactly equal to a
  # documented cap is legal everywhere in this module.
  @max_wire_message_size 2 * 1024 * 1024

  # Wall-clock budget for one wire frame to go from "first byte seen" to "fully
  # parsed" once @max_wire_message_size has let it start buffering at all. Without
  # this, a peer that declares a length just under that ceiling and then trickles
  # the body in a few bytes at a time holds up to @max_wire_message_size of `buffer`
  # per connection indefinitely: every delivery is real socket activity, so unlike a
  # genuinely idle connection it never falls quiet long enough to trip a plain
  # inactivity timer. The watchdog started in track_frame_stall/1 is deliberately
  # independent of this GenServer's own keep-alive cadence (@timeout): it is set
  # once when a partial frame starts accumulating and is only cleared by real
  # progress (a full message parsing out of `buffer`) -- receiving more bytes of the
  # SAME stalled frame never pushes it out. libtorrent pairs its recv-buffer ceiling
  # with exactly this (settings_pack::peer_timeout) for the same reason.
  @max_frame_assembly_time @timeout

  defstruct [:socket, :buffer, :key, active: false, utp_held_bytes: 0, frame_stall_ref: nil]

  @type socket :: Peer.Transport.socket()

  @type t :: %__MODULE__{
          socket: socket(),
          buffer: binary(),
          key: Peer.key(),
          active: boolean(),
          utp_held_bytes: non_neg_integer(),
          frame_stall_ref: reference() | nil
        }

  def start_link([hash, id, socket]) do
    key = Peer.make_key(hash, id)
    state = %__MODULE__{socket: socket, buffer: <<>>, key: key, active: false}
    GenServer.start_link(__MODULE__, state, name: via(key))
  end

  @spec activate(Peer.key()) :: :ok | {:error, term()}
  def activate(key) do
    GenServer.call(via(key), :activate, 5_000)
  catch
    :exit, _ -> {:error, :noproc}
  end

  @spec deactivate(Peer.key()) :: :ok | {:error, term()}
  def deactivate(key) do
    GenServer.call(via(key), :deactivate, 5_000)
  catch
    :exit, _ -> {:error, :noproc}
  end

  @spec choke(Peer.key()) :: :ok
  def choke(key), do: GenServer.cast(via(key), :choke)

  @spec unchoke(Peer.key()) :: :ok
  def unchoke(key), do: GenServer.cast(via(key), :unchoke)

  @spec interested(Peer.key()) :: :ok
  def interested(key), do: GenServer.cast(via(key), :interested)

  @spec not_interested(Peer.key()) :: :ok
  def not_interested(key), do: GenServer.cast(via(key), :not_interested)

  @spec interested(Peer.key(), boolean()) :: :ok
  def interested(key, true), do: interested(key)

  def interested(key, false), do: not_interested(key)

  @spec have(Peer.key(), Torrent.index()) :: :ok
  def have(key, index), do: GenServer.cast(via(key), {:have, index})

  @spec have_all(Peer.key()) :: :ok
  def have_all(key), do: GenServer.cast(via(key), :have_all)

  @spec have_none(Peer.key()) :: :ok
  def have_none(key), do: GenServer.cast(via(key), :have_none)

  @spec bitfield(Peer.key()) :: :ok
  def bitfield(key),
    do: GenServer.cast(via(key), {:bitfield, Peer.key_to_hash(key)})

  @spec request(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def request(key, index, begin, length),
    do: GenServer.cast(via(key), {:request, index, begin, length})

  @spec piece(Peer.key(), Torrent.index(), Torrent.begin(), iodata()) :: :ok
  def piece(key, index, begin, block),
    do: GenServer.cast(via(key), {:piece, index, begin, block})

  @spec cancel(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def cancel(key, index, begin, length),
    do: GenServer.cast(via(key), {:cancel, index, begin, length})

  @spec port(Peer.key(), :inet.port_number()) :: :ok
  def port(key, port), do: GenServer.cast(via(key), {:port, port})

  @spec suggest_piece(Peer.key(), Torrent.index()) :: :ok
  def suggest_piece(key, index),
    do: GenServer.cast(via(key), {:suggest_piece, index})

  @spec reject(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def reject(key, index, begin, length),
    do: GenServer.cast(via(key), {:reject, index, begin, length})

  @spec allowed_fast(Peer.key(), Torrent.index()) :: :ok
  def allowed_fast(key, index),
    do: GenServer.cast(via(key), {:allowed_fast, index})

  @spec hash_request(Peer.key(), Peer.HashWire.t()) :: :ok
  def hash_request(key, %Peer.HashWire{} = req),
    do: GenServer.cast(via(key), {:hash_request, req})

  @spec hashes(Peer.key(), Peer.HashWire.t(), iodata()) :: :ok
  def hashes(key, %Peer.HashWire{} = req, digest_blob),
    do: GenServer.cast(via(key), {:hashes, req, digest_blob})

  @spec hash_reject(Peer.key(), Peer.HashWire.t()) :: :ok
  def hash_reject(key, %Peer.HashWire{} = req),
    do: GenServer.cast(via(key), {:hash_reject, req})

  @spec send_operations(Peer.key(), [term()]) :: :ok
  def send_operations(key, operations) when is_list(operations) do
    GenServer.call(via(key), {:send_operations, operations}, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec socket_send_raw(Peer.key(), iodata()) :: :ok | {:error, term()}
  def socket_send_raw(key, data) do
    GenServer.call(via(key), {:socket_send_raw, data}, 5_000)
  catch
    :exit, _ -> {:error, :noproc}
  end

  @doc false
  @spec socket_recv(Peer.key(), non_neg_integer(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def socket_recv(key, len, timeout) do
    timeout = if is_integer(timeout), do: max(timeout, 0), else: timeout
    call_timeout = if is_integer(timeout), do: timeout + 5_000, else: timeout
    GenServer.call(via(key), {:socket_recv, len, timeout}, call_timeout)
  catch
    :exit, _ -> {:error, :noproc}
  end

  def init(state), do: {:ok, state, @timeout}

  def handle_call(:activate, _, %__MODULE__{socket: socket, active: false} = state) do
    case Peer.Transport.setopts(socket, active: true) do
      :ok ->
        {buffer, held} = absorb_kernel_buffer(socket, state.buffer)

        state = %{
          state
          | active: true,
            buffer: buffer,
            utp_held_bytes: state.utp_held_bytes + held
        }

        send(self(), :drain_buffered)
        {:reply, :ok, state, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call(:activate, _, %{active: true} = state) do
    {:reply, :ok, state, @timeout}
  end

  def handle_call(:deactivate, _, %__MODULE__{active: true, socket: socket} = state) do
    case Peer.Transport.setopts(socket, active: false) do
      :ok ->
        {buffer, held} = absorb_kernel_buffer(socket, state.buffer)

        state = %{
          state
          | active: false,
            buffer: buffer,
            utp_held_bytes: state.utp_held_bytes + held,
            # Going inactive leaves the wire-framing model entirely (bytes are
            # pulled via socket_recv/3 instead) -- any watchdog left running from
            # active-mode buffering would otherwise fire against a buffer that
            # inactive-mode code no longer interprets as "one stalled frame".
            frame_stall_ref: nil
        }

        {:reply, :ok, state, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call(:deactivate, _, %{active: false} = state) do
    {:reply, :ok, state, @timeout}
  end

  def handle_call({:socket_send_raw, data}, _, %__MODULE__{socket: socket} = state) do
    {:reply, Peer.Transport.safe_send(socket, data), state, @timeout}
  end

  # Used during magnet swarm metadata fetch (Sender inactive) and LTEP startup.
  def handle_call({:socket_recv, len, timeout}, _, %__MODULE__{active: false} = state) do
    case recv_inactive(state, len, timeout) do
      {:ok, data, new_state} ->
        {:reply, {:ok, data}, release_utp_if_buffer_empty(new_state), @timeout}

      {:error, _} = error ->
        {:reply, error, state, @timeout}
    end
  end

  def handle_call({:socket_recv, _, _}, _, %{active: true} = state) do
    {:reply, {:error, :active}, state, @timeout}
  end

  def handle_call({:send_operations, operations}, _, %__MODULE__{socket: socket} = state) do
    socket =
      Enum.reduce(operations, socket, fn
        :choke, sock ->
          do_send_sync(sock, @choke_id)

        :not_interested, sock ->
          do_send_sync(sock, @not_interested_id)

        {:cancel, index, begin, len}, sock ->
          do_send_sync(sock, [@cancel_id, <<index::32>>, <<begin::32>>, <<len::32>>])
      end)

    {:reply, :ok, %{state | socket: socket}, @timeout}
  catch
    :send_failed -> {:stop, :normal, state}
  end

  def handle_cast(:choke, state), do: do_send(state, @choke_id)

  def handle_cast(:unchoke, state), do: do_send(state, @unchoke_id)

  def handle_cast(:interested, state),
    do: do_send(state, @interested_id)

  def handle_cast(:not_interested, state),
    do: do_send(state, @not_interested_id)

  def handle_cast({:have, index}, state),
    do: do_send(state, [@have_id, <<index::32>>])

  def handle_cast(:have_all, state),
    do: do_send(state, @have_all_id)

  def handle_cast(:have_none, state),
    do: do_send(state, @have_none_id)

  def handle_cast({:bitfield, hash}, state),
    do: do_send(state, [@bitfield_id, Torrent.get(hash, :bitfield)])

  def handle_cast({:request, index, begin, len}, state),
    do: do_send(state, [@request_id, <<index::32>>, <<begin::32>>, <<len::32>>])

  def handle_cast({:piece, index, begin, block}, state),
    do: do_send(state, [@piece_id, <<index::32>>, <<begin::32>>, block])

  def handle_cast({:cancel, index, begin, len}, state),
    do: do_send(state, [@cancel_id, <<index::32>>, <<begin::32>>, <<len::32>>])

  def handle_cast({:port, port}, state),
    do: do_send(state, [@port_id, <<port::16>>])

  def handle_cast({:suggest_piece, index}, state),
    do: do_send(state, [@suggest_piece_id, <<index::32>>])

  def handle_cast({:reject, ind, beg, len}, state),
    do: do_send(state, [@reject_request_id, <<ind::32>>, <<beg::32>>, <<len::32>>])

  def handle_cast({:allowed_fast, index}, state),
    do: do_send(state, [@allowed_fast_id, <<index::32>>])

  def handle_cast({:hash_request, req}, state),
    do: do_send(state, [@hash_request_id, Peer.HashWire.encode_request(req)])

  def handle_cast({:hashes, req, digests}, state),
    do: do_send(state, [@hashes_id, Peer.HashWire.encode_hashes(req, digests)])

  def handle_cast({:hash_reject, req}, state),
    do: do_send(state, [@hash_reject_id, Peer.HashWire.encode_reject(req)])

  def handle_info(:drain_buffered, state), do: drain_inbound(state)

  # MSE: active-mode data is tagged with the inner (raw) socket and is ciphertext;
  # decrypt with the inbound RC4 stream before buffering.
  def handle_info(
        {:tcp, raw, data},
        %__MODULE__{socket: {:mse, raw, ciphers}, active: false} = state
      ) do
    buffer_inbound(state, Peer.MSE.crypt(ciphers.recv, data))
  end

  def handle_info(
        {:utp, raw, data},
        %__MODULE__{socket: {:mse, raw, ciphers}, active: false} = state
      ) do
    state
    |> hold_active_utp(data)
    |> buffer_inbound(Peer.MSE.crypt(ciphers.recv, data))
  end

  def handle_info({:tcp, raw, data}, %__MODULE__{socket: {:mse, raw, ciphers}} = state) do
    drain_inbound(%{state | buffer: state.buffer <> Peer.MSE.crypt(ciphers.recv, data)})
  end

  def handle_info({:utp, raw, data}, %__MODULE__{socket: {:mse, raw, ciphers}} = state) do
    state = hold_active_utp(state, data)
    drain_inbound(%{state | buffer: state.buffer <> Peer.MSE.crypt(ciphers.recv, data)})
  end

  def handle_info({:tcp, socket, data}, %{socket: socket, active: false} = state) do
    buffer_inbound(state, data)
  end

  def handle_info({:utp, socket, data}, %{socket: socket, active: false} = state) do
    state
    |> hold_active_utp(data)
    |> buffer_inbound(data)
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    drain_inbound(%{state | buffer: state.buffer <> data})
  end

  def handle_info({:utp, socket, data}, %{socket: socket} = state) do
    state = hold_active_utp(state, data)
    drain_inbound(%{state | buffer: state.buffer <> data})
  end

  # {:shutdown, :connection_closed} (not bare :normal): Peer supervisor uses
  # auto_shutdown on significant children — a distinct shutdown reason keeps
  # Sender terminate logs / future Endpoints mapping readable vs protocol_error.
  def handle_info({:tcp_closed, _}, state), do: {:stop, {:shutdown, :connection_closed}, state}

  def handle_info({:utp_closed, _}, state), do: {:stop, {:shutdown, :connection_closed}, state}

  def handle_info({:tcp_error, _, _}, state), do: {:stop, {:shutdown, :connection_closed}, state}

  def handle_info({:utp_error, _, _}, state), do: {:stop, {:shutdown, :connection_closed}, state}

  def handle_info(:timeout, state), do: do_send(state, [])

  # Fires @max_frame_assembly_time after some partial frame started accumulating in
  # `buffer` (see track_frame_stall/1). `ref` only matches state.frame_stall_ref when
  # that SAME partial frame is still stuck -- if it completed, or deactivate/1 reset
  # tracking, in the meantime, frame_stall_ref has moved on (nil or a newer ref) and
  # this message is stale and dropped. Cheaper than Process.cancel_timer/1 on every
  # completed frame, and just as race-free: a cancel racing the timer's own send
  # would need this same staleness check anyway.
  def handle_info({:frame_stall, ref}, %__MODULE__{frame_stall_ref: ref, key: key} = state) do
    Acceptor.malicious_peer(Peer.key_to_id(key))
    {:stop, {:shutdown, :frame_stalled}, state}
  end

  def handle_info({:frame_stall, _stale_ref}, state), do: {:noreply, state, @timeout}

  def terminate(reason, %__MODULE__{key: key}) do
    case reason do
      :normal ->
        Logger.debug(
          "[peer_sender] stopped peer=#{Peer.log_key(key)} hash=#{Torrent.hex_encoded_hash(Peer.key_to_hash(key))} reason=normal"
        )

      {:shutdown, _} = r ->
        Logger.debug(
          "[peer_sender] stopped peer=#{Peer.log_key(key)} hash=#{Torrent.hex_encoded_hash(Peer.key_to_hash(key))} reason=#{inspect(r)}"
        )

      _ ->
        Logger.warning(
          "[peer_sender] stopped peer=#{Peer.log_key(key)} hash=#{Torrent.hex_encoded_hash(Peer.key_to_hash(key))} reason=#{inspect(reason)}"
        )
    end

    :ok
  end

  @spec drain_inbound(t()) ::
          {:noreply, t(), timeout()} | {:stop, {:shutdown, :protocol_error}, t()}
  # BEP 9 swarm metadata: Magnet.Connection deactivates Sender and reads via
  # socket_recv/3. uTP has no passive mode (setopts active:false is unsupported),
  # so the connection keeps delivering {:utp,...} to us while inactive. Buffer those
  # bytes for socket_recv instead of drain_inbound — otherwise ut_metadata data/reject
  # replies are parsed and dropped before the metadata waiter sees them.
  defp buffer_inbound(%__MODULE__{} = state, data) do
    {:noreply, %{state | buffer: state.buffer <> data}, @timeout}
  end

  defp drain_inbound(%__MODULE__{buffer: buffer, key: key} = state) do
    case take_message(buffer) do
      {:ok, message, rest} ->
        case parse(message, key) do
          :ok ->
            # A full frame just parsed -- real progress, so whatever is left in
            # `rest` (nothing, or the start of the next frame) earns a fresh
            # assembly window instead of inheriting this frame's deadline.
            state = track_frame_stall(%{state | buffer: rest, frame_stall_ref: nil})
            drain_inbound(state)

          :protocol_error ->
            Acceptor.malicious_peer(Peer.key_to_id(key))
            {:stop, {:shutdown, :protocol_error}, %{state | buffer: rest}}
        end

      :incomplete ->
        state = track_frame_stall(release_utp_if_buffer_empty(state))
        {:noreply, state, @timeout}

      :protocol_error ->
        Acceptor.malicious_peer(Peer.key_to_id(key))
        {:stop, {:shutdown, :protocol_error}, state}
    end
  end

  # Starts the stall watchdog the first time `buffer` holds an incomplete frame, and
  # leaves it alone on every later call for that SAME frame -- only drain_inbound's
  # `:ok` branch (real progress) is allowed to replace it. An empty buffer means
  # nothing is pending, so tracking is cleared instead.
  @spec track_frame_stall(t()) :: t()
  defp track_frame_stall(%{buffer: <<>>} = state), do: %{state | frame_stall_ref: nil}

  defp track_frame_stall(%{frame_stall_ref: nil} = state) do
    ref = make_ref()
    Process.send_after(self(), {:frame_stall, ref}, @max_frame_assembly_time)
    %{state | frame_stall_ref: ref}
  end

  defp track_frame_stall(state), do: state

  # Peer data can arrive after the last passive recv (LTEP) but before active:true.
  @spec absorb_kernel_buffer(Peer.Transport.socket(), binary()) ::
          {binary(), non_neg_integer()}
  defp absorb_kernel_buffer({:mse, inner, ciphers}, buffer) do
    case absorb_kernel_buffer(inner, <<>>) do
      {<<>>, held} -> {buffer, held}
      {pending, held} -> {buffer <> Peer.MSE.crypt(ciphers.recv, pending), held}
    end
  end

  defp absorb_kernel_buffer(socket, buffer) when is_port(socket) do
    {absorb_kernel_buffer_loop(socket, buffer), 0}
  end

  defp absorb_kernel_buffer({:utp, _} = socket, buffer) do
    case UTP.Connection.take_recv_buffer(socket) do
      <<>> -> {buffer, 0}
      pending -> {buffer <> pending, byte_size(pending)}
    end
  end

  defp hold_active_utp(state, data),
    do: %{state | utp_held_bytes: state.utp_held_bytes + byte_size(data)}

  defp release_utp_if_buffer_empty(%{buffer: <<>>, utp_held_bytes: held} = state)
       when held > 0 do
    UTP.Connection.active_recv_consumed(utp_socket(state.socket), held)
    %{state | utp_held_bytes: 0}
  end

  defp release_utp_if_buffer_empty(state), do: state

  defp utp_socket({:mse, inner, _ciphers}), do: utp_socket(inner)
  defp utp_socket({:utp, _} = socket), do: socket

  defp absorb_kernel_buffer_loop(socket, buffer) do
    case :gen_tcp.recv(socket, 65_536, 0) do
      {:ok, data} when byte_size(data) > 0 ->
        absorb_kernel_buffer_loop(socket, buffer <> data)

      _ ->
        buffer
    end
  end

  @spec recv_inactive(t(), non_neg_integer(), timeout()) ::
          {:ok, binary(), t()} | {:error, term()}
  defp recv_inactive(%__MODULE__{buffer: buffer, socket: socket} = state, len, timeout) do
    if byte_size(buffer) >= len do
      take_from_buffer(state, buffer, len)
    else
      recv_inactive_fetch(state, socket, buffer, len, timeout)
    end
  end

  defp take_from_buffer(state, buffer, len) do
    <<data::binary-size(^len), rest::binary>> = buffer
    {:ok, data, %{state | buffer: rest}}
  end

  defp recv_inactive_fetch(state, socket, buffer, len, timeout) do
    need = len - byte_size(buffer)

    case Peer.Transport.safe_recv(socket, need, timeout) do
      {:ok, chunk} ->
        recv_inactive_combine(state, buffer <> chunk, len)

      {:error, _} = error ->
        error
    end
  end

  defp recv_inactive_combine(state, combined, len) do
    if byte_size(combined) >= len do
      <<data::binary-size(^len), rest::binary>> = combined
      {:ok, data, %{state | buffer: rest}}
    else
      recv_inactive(%{state | buffer: combined}, len, 0)
    end
  end

  # Pure wire framing: buffer -> one complete message. The 4-byte length prefix is
  # attacker-controlled (up to 2^32-1) and the generic clause below waits until the
  # buffer holds `len` bytes, so every message type with a known legitimate maximum
  # must be rejected *from its prefix* — otherwise one peer makes us grow the recv
  # buffer to an arbitrary size before we ever look at the body (libtorrent caps the
  # recv buffer the same way, disconnecting with errors::packet_too_large).
  #
  # The global @max_wire_message_size ceiling runs first, so an absurd length is
  # fatal for *every* id — known, or unknown-and-therefore-ignored. The per-id caps
  # after it then tighten each known id down to its own legitimate maximum.
  #
  # This layer only has the buffer; the per-torrent bound for `bitfield`
  # (ceil(pieces_count / 8)) is deliberately not applied here: pieces_count lives in
  # Torrent.Model, reachable only through a GenServer.call per frame on the hot wire
  # path, and during a magnet fetch it is still the Magnet.Bootstrap placeholder
  # (1 piece) while real peers legitimately send their full-size bitfield — which
  # Peer.Controller.State.do_handle_bitfield/2 accepts as have_all. The exact
  # per-torrent length check stays there; here we only stop the amplification.
  @spec take_message(binary()) :: {:ok, binary(), binary()} | :incomplete | :protocol_error
  # Size, not identity, is what makes this fatal — the id byte is not even matched
  # (`_::binary` also matches <<>>), so a bare 4-byte prefix declaring gigabytes is
  # rejected the moment it lands, one byte earlier than any per-id guard could act.
  # BEP 3 forward-compat is untouched: an unknown id at a sane length still falls
  # through to parse/2, which ignores it.
  defp take_message(<<len::32, _::binary>>) when len > @max_wire_message_size,
    do: :protocol_error

  defp take_message(<<len::32, @extended_id, _::binary>>)
       when len > @max_extended_message_size,
       do: :protocol_error

  defp take_message(<<len::32, @extended_id, @ut_metadata_local_id, _::binary>>)
       when len > @max_ut_metadata_message_size,
       do: :protocol_error

  defp take_message(<<len::32, id, _::binary>>)
       when id in [21, 23] and len > @max_hash_header_message_size,
       do: :protocol_error

  defp take_message(<<len::32, 22, _::binary>>) when len > @max_hashes_message_size,
    do: :protocol_error

  defp take_message(<<len::32, @bitfield_id, _::binary>>)
       when len > @max_bitfield_message_size,
       do: :protocol_error

  defp take_message(<<len::32, @piece_id, _::binary>>)
       when len > @max_piece_message_size,
       do: :protocol_error

  defp take_message(<<len::32, rest::binary>>) when byte_size(rest) >= len do
    message = binary_part(rest, 0, len)
    rest2 = binary_part(rest, len, byte_size(rest) - len)
    {:ok, message, rest2}
  end

  defp take_message(_), do: :incomplete

  # Core + DHT port + Fast + LTEP + BEP 52 hash transfer (21–23).
  @known_wire_ids [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 20, 21, 22, 23]

  defguardp is_known_wire_id(id) when id in @known_wire_ids

  @doc false
  @spec known_wire_id?(integer()) :: boolean()
  def known_wire_id?(id) when is_integer(id), do: id in @known_wire_ids

  @doc false
  @spec max_bitfield_message_size() :: pos_integer()
  def max_bitfield_message_size, do: @max_bitfield_message_size

  @doc false
  @spec max_wire_message_size() :: pos_integer()
  def max_wire_message_size, do: @max_wire_message_size

  defp parse(<<>>, _), do: :ok

  defp parse(@choke_id, key), do: handle_choke(key)

  defp parse(@unchoke_id, key) do
    log_wire(key, "unchoke", :debug)
    handle_unchoke(key)
  end

  defp parse(@interested_id, key), do: handle_interested(key)

  defp parse(@not_interested_id, key),
    do: handle_not_interested(key)

  defp parse(<<@have_id, index::32>>, key),
    do: handle_have(key, index)

  defp parse(@have_all_id, key) do
    log_wire(key, "have_all", :debug)
    handle_have_all(key)
  end

  defp parse(@have_none_id, key), do: handle_have_none(key)

  defp parse(<<@bitfield_id, bitfield::binary>>, key) do
    log_wire(key, "bitfield bytes=#{byte_size(bitfield)}", :debug)
    handle_bitfield(key, bitfield)
  end

  defp parse(<<@request_id, _::32, _::32, length::32>>, _)
       when length > @max_length,
       do: :protocol_error

  defp parse(<<@request_id, index::32, begin::32, length::32>>, key),
    do: handle_request(key, index, begin, length)

  defp parse(<<@piece_id, index::32, begin::32, block::binary>>, key) do
    log_wire(key, "piece index=#{index} begin=#{begin} bytes=#{byte_size(block)}")
    handle_piece(key, index, begin, block)
  end

  defp parse(<<@cancel_id, index::32, begin::32, length::32>>, key),
    do: handle_cancel(key, index, begin, length)

  defp parse(<<@port_id, port::16>>, key),
    do: handle_port(key, port)

  defp parse(<<@suggest_piece_id, index::32>>, key),
    do: handle_suggest_piece(key, index)

  defp parse(<<@reject_request_id, index::32, begin::32, len::32>>, key),
    do: handle_reject(key, index, begin, len)

  defp parse(<<@allowed_fast_id, index::32>>, key),
    do: handle_allowed_fast(key, index)

  defp parse(<<@extended_id, extended_id::8, payload::binary>>, key),
    do: handle_extended(key, extended_id, payload)

  defp parse(<<@hash_request_id, payload::binary>>, key) do
    case Peer.HashWire.decode_request(payload) do
      {:ok, req} -> handle_hash_request(key, req)
      _ -> :protocol_error
    end
  end

  defp parse(<<@hashes_id, payload::binary>>, key) do
    with {:ok, req, hashes} <- Peer.HashWire.decode_hashes(payload),
         :ok <- Peer.HashWire.validate_hashes_payload(req, hashes) do
      handle_hashes(key, req, hashes)
    else
      _ -> :protocol_error
    end
  end

  defp parse(<<@hash_reject_id, payload::binary>>, key) do
    case Peer.HashWire.decode_request(payload) do
      {:ok, req} -> handle_hash_reject(key, req)
      _ -> :protocol_error
    end
  end

  # BEP 3 forward-compat: unknown message *types* are ignored (libtorrent /
  defp parse(<<id, _::binary>> = msg, key) when not is_known_wire_id(id) do
    log_wire(key, "ignored_unknown id=#{id} bytes=#{byte_size(msg)}", :debug)
    :ok
  end

  defp parse(_, _), do: :protocol_error

  defp do_send(%__MODULE__{socket: socket} = state, msg) do
    case transport_send(socket, msg) do
      :ok -> {:noreply, state, @timeout}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp do_send_sync(socket, msg) do
    case transport_send(socket, msg) do
      :ok -> socket
      {:error, _reason} -> throw(:send_failed)
    end
  end

  @spec transport_send(Peer.Transport.socket(), iodata()) :: :ok | {:error, term()}
  defp transport_send(socket, msg) do
    # safe_send: uTP owner may exit between a wire cast (e.g. DHT {:port,6881})
    # and the write — common under CGNAT churn; stop cleanly instead of crashing.
    Peer.Transport.safe_send(socket, [<<IO.iodata_length(msg)::32>>, msg])
  end

  @spec log_wire(Peer.key(), String.t(), :info | :debug) :: :ok
  defp log_wire(key, event, level \\ :debug) do
    line =
      "[peer_wire] peer=#{Peer.log_key(key)} hash=#{Torrent.hex_encoded_hash(Peer.key_to_hash(key))} #{event}"

    case level do
      :info -> Logger.info(line)
      _ -> Logger.debug(line)
    end
  end
end

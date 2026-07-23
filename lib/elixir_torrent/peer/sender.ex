defmodule Peer.Sender do
  # restart overridden to :temporary in Peer.start_link (auto_shutdown tree).
  use GenServer, restart: :temporary
  use Via
  use Peer.Const

  import Peer.Controller

  require Logger

  @timeout 100_000
  @max_length Torrent.Downloads.piece_max_length()

  defstruct [:socket, :buffer, :key, active: false]

  @type socket :: :gen_tcp.socket() | UTP.Connection.socket_ref()

  @type t :: %__MODULE__{
          socket: socket(),
          buffer: binary(),
          key: Peer.key(),
          active: boolean()
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
  @spec socket_recv(Peer.key(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
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
        state = %{state | active: true, buffer: absorb_kernel_buffer(socket, state.buffer)}
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
        buffer = absorb_kernel_buffer(socket, state.buffer)
        {:reply, :ok, %{state | active: false, buffer: buffer}, @timeout}

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
      {:ok, data, new_state} -> {:reply, {:ok, data}, new_state, @timeout}
      {:error, _} = error -> {:reply, error, state, @timeout}
    end
  end

  def handle_call({:socket_recv, _, _}, _, %{active: true} = state) do
    {:reply, {:error, :active}, state, @timeout}
  end

  def handle_call({:send_operations, operations}, _, %__MODULE__{socket: socket} = state) do
    try do
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

  def handle_info(:drain_buffered, state), do: drain_inbound(state)

  # MSE: active-mode data is tagged with the inner (raw) socket and is ciphertext;
  # decrypt with the inbound RC4 stream before buffering.
  def handle_info({:tcp, raw, data}, %__MODULE__{socket: {:mse, raw, ciphers}, active: false} = state) do
    buffer_inbound(state, Peer.MSE.crypt(ciphers.recv, data))
  end

  def handle_info({:utp, raw, data}, %__MODULE__{socket: {:mse, raw, ciphers}, active: false} = state) do
    buffer_inbound(state, Peer.MSE.crypt(ciphers.recv, data))
  end

  def handle_info({:tcp, raw, data}, %__MODULE__{socket: {:mse, raw, ciphers}} = state) do
    drain_inbound(%{state | buffer: state.buffer <> Peer.MSE.crypt(ciphers.recv, data)})
  end

  def handle_info({:utp, raw, data}, %__MODULE__{socket: {:mse, raw, ciphers}} = state) do
    drain_inbound(%{state | buffer: state.buffer <> Peer.MSE.crypt(ciphers.recv, data)})
  end

  def handle_info({:tcp, socket, data}, %{socket: socket, active: false} = state) do
    buffer_inbound(state, data)
  end

  def handle_info({:utp, socket, data}, %{socket: socket, active: false} = state) do
    buffer_inbound(state, data)
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    drain_inbound(%{state | buffer: state.buffer <> data})
  end

  def handle_info({:utp, socket, data}, %{socket: socket} = state) do
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

  @spec drain_inbound(t()) :: GenServer.reply()
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
          :ok -> drain_inbound(%{state | buffer: rest})
          :protocol_error ->
            Acceptor.malicious_peer(Peer.key_to_id(key))
            {:stop, {:shutdown, :protocol_error}, %{state | buffer: rest}}
        end

      :incomplete ->
        {:noreply, state, @timeout}
    end
  end

  # Peer data can arrive after the last passive recv (LTEP) but before active:true.
  @spec absorb_kernel_buffer(Peer.Transport.socket(), binary()) :: binary()
  defp absorb_kernel_buffer({:mse, inner, ciphers}, buffer) do
    case absorb_kernel_buffer(inner, <<>>) do
      <<>> -> buffer
      pending -> buffer <> Peer.MSE.crypt(ciphers.recv, pending)
    end
  end

  defp absorb_kernel_buffer(socket, buffer) when is_port(socket) do
    absorb_kernel_buffer_loop(socket, buffer)
  end

  defp absorb_kernel_buffer({:utp, _} = socket, buffer) do
    case UTP.Connection.take_recv_buffer(socket) do
      <<>> -> buffer
      pending -> buffer <> pending
    end
  end

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
    cond do
      byte_size(buffer) >= len ->
        <<data::binary-size(^len), rest::binary>> = buffer
        {:ok, data, %{state | buffer: rest}}

      true ->
        need = len - byte_size(buffer)

        case Peer.Transport.safe_recv(socket, need, timeout) do
          {:ok, chunk} ->
            combined = buffer <> chunk

            if byte_size(combined) >= len do
              <<data::binary-size(^len), rest::binary>> = combined
              {:ok, data, %{state | buffer: rest}}
            else
              recv_inactive(%{state | buffer: combined}, len, 0)
            end

          {:error, _} = error ->
            error
        end
    end
  end

  @spec take_message(binary()) :: {:ok, binary(), binary()} | :incomplete
  defp take_message(<<len::32, rest::binary>>) when byte_size(rest) >= len do
    message = binary_part(rest, 0, len)
    rest2 = binary_part(rest, len, byte_size(rest) - len)
    {:ok, message, rest2}
  end

  defp take_message(_), do: :incomplete

  # Core + DHT port + Fast + LTEP. Not BEP 52 hash_* (21–23) until phase 4.
  @known_wire_ids [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 14, 15, 16, 17, 20]

  defguardp is_known_wire_id(id) when id in @known_wire_ids

  @doc false
  @spec known_wire_id?(integer()) :: boolean()
  def known_wire_id?(id) when is_integer(id), do: id in @known_wire_ids

  defp parse(<<>>, _), do: :ok

  defp parse(@choke_id, key), do: handle_choke(key)

  defp parse(@unchoke_id, key) do
    log_wire(key, "unchoke", :info)
    handle_unchoke(key)
  end

  defp parse(@interested_id, key), do: handle_interested(key)

  defp parse(@not_interested_id, key),
    do: handle_not_interested(key)

  defp parse(<<@have_id, index::32>>, key),
    do: handle_have(key, index)

  defp parse(@have_all_id, key) do
    log_wire(key, "have_all", :info)
    handle_have_all(key)
  end

  defp parse(@have_none_id, key), do: handle_have_none(key)

  defp parse(<<@bitfield_id, bitfield::binary>>, key) do
    log_wire(key, "bitfield bytes=#{byte_size(bitfield)}", :info)
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

  # BEP 3 forward-compat: unknown message *types* are ignored (libtorrent /
  # qBittorrent do the same). BEP 52 `hash_request`/`hashes`/`hash_reject`
  # (ids 21–23) hit this path today — treating them as protocol_error was
  # tearing down otherwise-healthy peers via one_for_all + max_restarts:0.
  # Malformed payloads of *known* ids still fall through to protocol_error.
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

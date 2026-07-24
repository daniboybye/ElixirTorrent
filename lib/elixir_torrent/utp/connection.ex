defmodule UTP.Connection do
  @moduledoc false
  use GenServer
  require Logger

  alias UTP.{LEDBAT, Packet}

  @st_data Packet.st_data()
  @st_fin Packet.st_fin()
  @st_state Packet.st_state()
  @st_reset Packet.st_reset()
  @st_syn Packet.st_syn()

  @initial_timeout_ms 1_000
  @min_timeout_ms 500
  @max_packet_payload 1_400
  @min_packet_payload 150
  @recv_buffer_max 65_536
  @tick_ms 50
  # After shutdown we linger briefly so any final ACK for a FIN we sent can
  # arrive before we exit, then stop the process. Without this, shutdown/2 only
  # flipped a flag and left the GenServer running forever, ticking every 50ms.
  @linger_ms 1_000

  defstruct [
    :udp_socket,
    :peer_ip,
    :peer_port,
    :recv_conn_id,
    :send_conn_id,
    :socket_ref,
    :owner,
    :owner_ref,
    role: :client,
    phase: :syn_sent,
    seq_nr: 1,
    ack_nr: 0,
    last_peer_ack: 0,
    eof_seq: nil,
    recv_next: 1,
    recv_oob: %{},
    unacked: %{},
    dup_acks: 0,
    rtt_us: 100_000,
    rtt_var_us: 0,
    timeout_ms: @initial_timeout_ms,
    timeout_count: 0,
    peer_wnd: 65_536,
    cur_window: 0,
    reply_micro: 0,
    led: nil,
    active: false,
    recv_buffer: <<>>,
    pending_send: <<>>,
    recv_waiters: [],
    timer_ref: nil,
    last_send_ms: 0,
    last_recv_ms: 0,
    fin_sent: false,
    closed: false,
    accept_notified: false
  ]

  @type socket_ref :: {:utp, pid()}

  @spec start_client(port(), :inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, socket_ref()} | {:error, term()}
  def start_client(udp_socket, ip, port, opts \\ []) do
    recv_conn_id = Keyword.get(opts, :conn_id, :rand.uniform(65_534))
    send_conn_id = rem(recv_conn_id + 1, 65536)
    start_link(udp_socket, ip, port, :client, :syn_sent, recv_conn_id, send_conn_id, 1)
  end

  @spec start_server(port(), :inet.ip_address(), :inet.port_number(), 0..65535) ::
          {:ok, socket_ref()} | {:error, term()}
  def start_server(udp_socket, ip, port, syn_conn_id) do
    recv_conn_id = rem(syn_conn_id + 1, 65536)
    send_conn_id = syn_conn_id
    seq_nr = :rand.uniform(65535)
    start_link(udp_socket, ip, port, :server, :syn_recv, recv_conn_id, send_conn_id, seq_nr)
  end

  @spec send_raw(socket_ref(), iodata()) :: :ok | {:error, term()}
  def send_raw({:utp, pid}, data) do
    GenServer.call(pid, {:send, data}, 60_000)
  catch
    :exit, reason -> {:error, Peer.Transport.peer_exit_reason(reason)}
  end

  @spec recv_raw(socket_ref(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv_raw({:utp, pid}, len, timeout) do
    GenServer.call(pid, {:recv, len, timeout}, timeout + 5_000)
  catch
    :exit, reason -> {:error, Peer.Transport.peer_exit_reason(reason)}
  end

  @spec activate(socket_ref()) :: :ok | {:error, term()}
  def activate({:utp, pid}), do: GenServer.call(pid, :activate, 5_000)

  @doc false
  @spec deactivate(socket_ref()) :: :ok | {:error, term()}
  def deactivate({:utp, pid}), do: GenServer.call(pid, :deactivate, 5_000)

  @doc false
  @spec take_recv_buffer(socket_ref()) :: binary()
  def take_recv_buffer({:utp, pid}) do
    GenServer.call(pid, :take_recv_buffer, 5_000)
  catch
    :exit, _ -> <<>>
  end

  @spec controlling_process(socket_ref(), pid()) :: :ok | {:error, term()}
  def controlling_process({:utp, pid}, owner),
    do: GenServer.call(pid, {:controlling_process, owner}, 5_000)

  @spec close(socket_ref()) :: :ok
  def close({:utp, pid}), do: GenServer.cast(pid, :close)

  @spec peername(socket_ref()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def peername({:utp, pid}) do
    GenServer.call(pid, :peername)
  catch
    :exit, reason -> {:error, Peer.Transport.peer_exit_reason(reason)}
  end

  @spec await_connected(socket_ref(), timeout()) :: :ok | {:error, term()}
  def await_connected({:utp, pid}, timeout \\ 5_000) do
    try do
      :ok = GenServer.call(pid, :await_connected, timeout + 500)
      :ok
    catch
      :exit, _ -> {:error, :timeout}
    end
  end

  defp start_link(udp_socket, ip, port, role, phase, recv_conn_id, send_conn_id, seq_nr) do
    state = %__MODULE__{
      udp_socket: udp_socket,
      peer_ip: ip,
      peer_port: port,
      role: role,
      phase: phase,
      recv_conn_id: recv_conn_id,
      send_conn_id: send_conn_id,
      seq_nr: seq_nr,
      led: LEDBAT.new(),
      last_send_ms: now_ms(),
      last_recv_ms: now_ms()
    }

    # start/3 (not start_link) — a send failure must not crash UTP.Dispatcher.
    case GenServer.start(__MODULE__, state, []) do
      {:ok, pid} ->
        ref = {:utp, pid}
        :ok = UTP.Dispatcher.register_pair(recv_conn_id, send_conn_id, ip, port, pid)

        state = %{
          state
          | socket_ref: ref,
            recv_next: if(role == :server, do: seq_nr, else: 1)
        }

        :ok = GenServer.cast(pid, {:boot, state})

        {:ok, ref}

      other ->
        other
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:boot, state}, _old) do
    state = schedule_tick(state)

    state =
      case state.role do
        :client ->
          transmit(state, @st_syn, <<>>, state.seq_nr, true)

        :server ->
          state
      end

    {:noreply, state}
  end

  def handle_cast(:close, state) do
    state =
      if state.phase == :connected and not state.fin_sent do
        send_fin(state)
      else
        state
      end

    {:stop, :normal, shutdown(state, :normal)}
  end

  @impl true
  def handle_call(:activate, _from, %{active: false} = state) do
    {:reply, :ok, %{state | active: true}}
  end

  def handle_call(:activate, _from, state), do: {:reply, :ok, state}

  def handle_call(:deactivate, _from, %{active: true} = state) do
    {:reply, :ok, %{state | active: false}}
  end

  def handle_call(:deactivate, _from, state), do: {:reply, :ok, state}

  def handle_call(:take_recv_buffer, _from, state) do
    {buffer, state} = {state.recv_buffer, %{state | recv_buffer: <<>>}}
    {:reply, buffer, state}
  end

  def handle_call({:controlling_process, owner}, _from, state) when is_pid(owner) do
    if state.owner_ref, do: Process.demonitor(state.owner_ref, [:flush])
    ref = Process.monitor(owner)
    {:reply, :ok, %{state | owner: owner, owner_ref: ref}}
  end

  def handle_call(:await_connected, _from, %{phase: :connected} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_connected, from, state) do
    {:noreply, %{state | recv_waiters: state.recv_waiters ++ [{from, :connected}]}}
  end

  def handle_call({:send, data}, _from, state) do
    state = %{state | pending_send: state.pending_send <> IO.iodata_to_binary(data)}
    state = flush_send(state)
    {:reply, :ok, state}
  end

  def handle_call({:recv, len, timeout}, from, state) do
    if byte_size(state.recv_buffer) >= len do
      {chunk, rest} = take_bytes(state.recv_buffer, len)
      {:reply, {:ok, chunk}, %{state | recv_buffer: rest}}
    else
      timer_ref = Process.send_after(self(), {:recv_timeout, from}, max(timeout, 0))
      {:noreply, %{state | recv_waiters: state.recv_waiters ++ [{from, len, timer_ref}]}}
    end
  end

  def handle_call(:peername, _from, %{peer_ip: ip, peer_port: port} = state) do
    {:reply, {:ok, {ip, port}}, state}
  end

  @impl true
  def handle_info({:utp_packet, header, payload, extensions}, state) do
    {:noreply, handle_inbound(state, header, payload, extensions) |> flush_send()}
  end

  def handle_info(:tick, state) do
    {:noreply, state |> check_timeouts() |> flush_send() |> schedule_tick()}
  end

  def handle_info({:recv_timeout, from}, state) do
    waiters = Enum.reject(state.recv_waiters, fn {f, _, _} -> f == from end)
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | recv_waiters: waiters}}
  end

  # Owner (Peer.Sender) died — tear down instead of ticking forever.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:noreply, shutdown(state, :owner_down)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # Fired @linger_ms after shutdown/2 — actually stop the GenServer.
  def handle_info(:stop_zombie, state), do: {:stop, :normal, state}

  defp handle_inbound(state, header, payload, extensions) do
    unless valid_conn_id?(state, header) do
      state
    else
      now_us = :os.system_time(:microsecond)
      reply_micro = max(now_us - header.timestamp, 0)

      state =
        state
        |> Map.put(:reply_micro, reply_micro)
        |> Map.put(:last_recv_ms, now_ms())
        |> Map.put(:peer_wnd, header.wnd_size)

      state =
        if state.phase == :connected do
          put_led(state, LEDBAT.record_delay(state.led, header.timestamp_difference))
        else
          state
        end

      # Update dup_acks BEFORE process_acks so the 3rd dup (dup_acks:=3) can
      # trigger fast-retransmit inside process_acks. The old order incremented
      # after, meaning we needed 4 duplicates to fire.
      state =
        if header.ack_nr == state.last_peer_ack do
          %{state | dup_acks: state.dup_acks + 1}
        else
          %{state | dup_acks: 0, last_peer_ack: header.ack_nr}
        end

      state = process_acks(state, header, extensions)

      case header.type do
        @st_reset ->
          shutdown(state, :reset)

        @st_state ->
          handle_state_packet(state, header)

        @st_data ->
          handle_data_packet(state, header, payload)

        @st_fin ->
          handle_fin_packet(state, header, payload)

        @st_syn ->
          cond do
            state.role == :server and state.phase == :syn_recv ->
              handle_syn_server(state, header)

            state.role == :client and state.phase == :syn_sent ->
              handle_state_packet(state, header)

            true ->
              state
          end

        _ ->
          state
      end
    end
  end

  defp handle_syn_server(state, header) do
    state
    |> Map.put(:ack_nr, header.seq_nr)
    |> Map.put(:recv_next, Packet.seq_add(header.seq_nr, 1))
    |> send_state_ack()
  end

  defp handle_state_packet(state, header) do
    cond do
      state.phase == :syn_sent and state.role == :client ->
        Logger.info(
          "[utp] connected client peer=#{inspect({state.peer_ip, state.peer_port})} recv_id=#{state.recv_conn_id}"
        )

        state
        |> Map.put(:phase, :connected)
        # libutp: on ST_STATE in SYN_SENT, ack_nr = peer_seq - 1; first DATA arrives at peer_seq.
        |> Map.put(:ack_nr, Packet.seq_add(header.seq_nr, -1))
        |> Map.put(:recv_next, header.seq_nr)
        |> send_state_ack()
        |> notify_connected_waiters()

      state.phase == :syn_recv and state.role == :server ->
        Logger.info(
          "[utp] connected server peer=#{inspect({state.peer_ip, state.peer_port})} recv_id=#{state.recv_conn_id}"
        )

        state
        |> Map.put(:phase, :connected)
        |> Map.put(:ack_nr, header.seq_nr)
        |> notify_connected_waiters()
        |> notify_accept_once()

      true ->
        send_state_ack(state)
    end
  end

  defp handle_data_packet(state, %{seq_nr: seq}, payload) do
    state =
      if state.phase == :syn_recv and state.role == :server do
        state
        |> Map.put(:phase, :connected)
        |> notify_connected_waiters()
        |> notify_accept_once()
      else
        state
      end

    if state.phase == :connected, do: ingest_seq(state, seq, payload, @st_data), else: state
  end

  defp handle_fin_packet(state, %{seq_nr: seq}, payload) do
    if state.phase == :connected do
      state
      |> Map.put(:eof_seq, seq)
      |> ingest_seq(seq, payload, @st_fin)
      |> maybe_close_on_eof()
    else
      state
    end
  end

  defp ingest_seq(state, seq, payload, type) do
    cond do
      seq == state.recv_next ->
        state
        |> deliver_payload(payload)
        |> Map.put(:recv_next, Packet.seq_add(seq, 1))
        |> Map.put(:ack_nr, seq)
        |> then(fn s -> if type == @st_fin, do: Map.put(s, :eof_seq, seq), else: s end)
        |> drain_oob()
        |> maybe_close_on_eof()
        |> send_state_ack()

      Packet.seq_after?(seq, state.recv_next) ->
        Logger.info(
          "[utp] oob_data peer=#{inspect({state.peer_ip, state.peer_port})} seq=#{seq} expected=#{state.recv_next} bytes=#{byte_size(payload)}"
        )

        recv_oob = Map.put(state.recv_oob, seq, {payload, type})

        %{state | recv_oob: recv_oob}
        |> send_state_ack()

      true ->
        Logger.debug(
          "[utp] drop_data peer=#{inspect({state.peer_ip, state.peer_port})} seq=#{seq} expected=#{state.recv_next} bytes=#{byte_size(payload)}"
        )

        send_state_ack(state)
    end
  end

  defp drain_oob(state) do
    Enum.reduce(1..256, state, fn _, acc ->
      case Map.get(acc.recv_oob, acc.recv_next) do
        {payload, type} ->
          acc =
            acc
            |> Map.put(:recv_oob, Map.delete(acc.recv_oob, acc.recv_next))
            |> deliver_payload(payload)
            |> Map.put(:ack_nr, acc.recv_next)
            |> Map.put(:recv_next, Packet.seq_add(acc.recv_next, 1))
            |> then(fn s -> if type == @st_fin, do: Map.put(s, :eof_seq, s.ack_nr), else: s end)

          acc

        nil ->
          acc
      end
    end)
  end

  defp deliver_payload(state, payload) when payload == <<>>, do: state

  defp deliver_payload(state, payload) do
    if state.active and is_pid(state.owner) do
      # Active mode: hand the bytes to the owner immediately. They never enter
      # our recv_buffer, so nothing to add to the flow-control accounting.
      send(state.owner, {:utp, state.socket_ref, payload})
      state
    else
      state = %{state | recv_buffer: state.recv_buffer <> payload}

      Logger.debug(
        "[utp] recv_data peer=#{inspect({state.peer_ip, state.peer_port})} bytes=#{byte_size(payload)} buffer=#{byte_size(state.recv_buffer)} waiters=#{recv_byte_waiters(state)}"
      )

      satisfy_recv_waiters(state)
    end
  end

  # Bytes currently held in RAM for this connection: delivered-but-unread in
  # the recv_buffer + out-of-order packets parked in recv_oob. This is the
  # true memory pressure and drives our advertised wnd_size in transmit/5.
  # Deriving it every send-time avoids the previous running-counter bug where
  # OOB payloads were charged twice and reader consumption never decremented.
  defp recv_bytes_held(state) do
    byte_size(state.recv_buffer) + oob_bytes(state)
  end

  defp oob_bytes(state) do
    Enum.reduce(state.recv_oob, 0, fn {_seq, {payload, _type}}, acc ->
      acc + byte_size(payload)
    end)
  end

  defp recv_byte_waiters(state) do
    state.recv_waiters
    |> Enum.count(fn
      {_, len, _} when is_integer(len) -> true
      _ -> false
    end)
  end

  defp process_acks(state, header, extensions) do
    selective_acks = Packet.selective_ack_acks(header, extensions)
    state = cumulative_ack(state, header.ack_nr)

    state =
      Enum.reduce(selective_acks, state, fn seq, acc -> ack_exact_seq(acc, seq) end)

    sack_losses =
      state.unacked
      |> Map.keys()
      |> Enum.filter(fn unacked_seq ->
        Enum.count(selective_acks, &Packet.seq_after?(&1, unacked_seq)) >= 3
      end)

    state = Enum.reduce(sack_losses, state, &retransmit_loss(&2, &1))

    if map_size(state.unacked) > 0 and header.ack_nr == state.last_peer_ack and
         state.dup_acks >= 3 do
      missing_seq = Packet.seq_add(header.ack_nr, 1)

      if missing_seq in sack_losses do
        state
      else
        retransmit_loss(state, missing_seq)
      end
    else
      state
    end
  end

  # Cumulative ACK. header.ack_nr acknowledges every previously-sent seq up to
  # and including that value (mod 2^16). We iterate the unacked map directly
  # instead of assuming a contiguous range: selective_ack punches holes, so the
  # old base = seq_nr - in_flight arithmetic dropped legitimate cumulative acks
  # (e.g. peer_ack_nr < seq_nr - in_flight after we selective-acked a middle
  # seq made every subsequent cumulative ack a no-op).
  defp cumulative_ack(%{unacked: unacked} = state, _peer_ack_nr)
       when map_size(unacked) == 0,
       do: state

  defp cumulative_ack(state, peer_ack_nr) do
    state.unacked
    |> Map.keys()
    |> Enum.filter(fn seq ->
      diff = Packet.seq_diff(peer_ack_nr, seq)
      diff >= 0
    end)
    |> Enum.reduce(state, fn seq, acc -> ack_exact_seq(acc, seq) end)
  end

  defp ack_exact_seq(state, seq) do
    case Map.pop(state.unacked, seq) do
      {nil, _} ->
        state

      {{_payload, sent_ms, tx_count, bytes}, unacked} ->
        Logger.debug(
          "[utp] acked seq=#{seq} peer=#{inspect({state.peer_ip, state.peer_port})} bytes=#{bytes} pending=#{map_size(unacked)}"
        )

        state =
          %{state | unacked: unacked, cur_window: max(state.cur_window - bytes, 0)}

        state =
          if tx_count == 1 do
            update_rtt(state, sent_ms)
          else
            state
          end

        put_led(state, LEDBAT.grow_window(state.led, state.cur_window, state.peer_wnd))
    end
  end

  defp retransmit_loss(state, seq) do
    case Map.get(state.unacked, seq) do
      {payload, _sent_ms, _tx_count, _bytes} ->
        state = put_led(state, LEDBAT.on_loss(state.led))
        # transmit/5 preserves and increments tx_count when re-sending an
        # already-unacked seq, so we no longer bump it manually here (the old
        # +1 was overwritten by transmit's map put with tx_count=1 → give-up
        # never fired).
        transmit(state, @st_data, payload, seq, false)

      nil ->
        state
    end
  end

  defp update_rtt(state, sent_ms) do
    packet_rtt_us = max(now_ms() - sent_ms, 1) * 1000
    delta = state.rtt_us - packet_rtt_us
    rtt_var = state.rtt_var_us + div(abs(delta) - state.rtt_var_us, 4)
    rtt_us = state.rtt_us + div(packet_rtt_us - state.rtt_us, 8)
    timeout_ms = max(div(rtt_us, 1000) + div(rtt_var * 4, 1000), @min_timeout_ms)
    %{state | rtt_us: rtt_us, rtt_var_us: rtt_var, timeout_ms: timeout_ms, timeout_count: 0}
  end

  defp flush_send(state) do
    if state.phase != :connected or state.pending_send == <<>> do
      state
    else
      flush_send_loop(state, state.pending_send)
    end
  end

  defp flush_send_loop(state, <<>>), do: %{state | pending_send: <<>>}

  defp flush_send_loop(state, pending) do
    size = effective_packet_size(state)
    chunk_size = min(byte_size(pending), size)

    if chunk_size > 0 and can_send?(state, chunk_size) do
      <<chunk::binary-size(^chunk_size), rest::binary>> = pending
      seq = state.seq_nr
      state = transmit(state, @st_data, chunk, seq, true)
      flush_send_loop(state, rest)
    else
      %{state | pending_send: pending}
    end
  end

  defp can_send?(state, size) do
    max_wnd = min(state.led.max_window, state.peer_wnd)
    state.cur_window + size <= max_wnd and map_size(state.unacked) < 512
  end

  defp effective_packet_size(%{led: %{max_window: wnd}}) when wnd <= @min_packet_payload,
    do: @min_packet_payload

  defp effective_packet_size(_), do: @max_packet_payload

  defp transmit(%{closed: true} = state, _type, _payload, _seq, _increment?), do: state

  defp transmit(state, type, payload, seq, increment?) do
    increment? = increment? and type != @st_state
    extensions = selective_ack_extensions(state)

    header = %Packet{
      type: type,
      version: 1,
      extension: if(extensions == [], do: 0, else: 1),
      conn_id: packet_conn_id(state, type),
      timestamp: rem(:os.system_time(:microsecond), 0x1_0000_0000),
      timestamp_difference: state.reply_micro,
      wnd_size: max(@recv_buffer_max - recv_bytes_held(state), 0),
      seq_nr: seq,
      ack_nr: state.ack_nr,
      extensions: extensions
    }

    wire = Packet.encode(header, payload)

    case send_udp_direct(state.udp_socket, state.peer_ip, state.peer_port, wire) do
      :ok ->
        if type == @st_data and byte_size(payload) > 0 do
          Logger.debug(
            "[utp] sent_data peer=#{inspect({state.peer_ip, state.peer_port})} seq=#{seq} bytes=#{byte_size(payload)} ack=#{state.ack_nr}"
          )
        end

        bytes = byte_size(payload)

        unacked =
          if type in [@st_data, @st_fin] do
            # Preserve the retransmit count across re-sends of the same seq so
            # check_timeouts' give-up (tx_count >= 10) actually fires. The old
            # code hard-coded tx_count=1 here, making retransmit_loss's manual
            # bump dead and the give-up branch unreachable.
            tx_count =
              case Map.get(state.unacked, seq) do
                {_, _, prev, _} -> prev + 1
                nil -> 1
              end

            Map.put(state.unacked, seq, {payload, now_ms(), tx_count, bytes})
          else
            state.unacked
          end

        cur_window = if bytes > 0, do: state.cur_window + bytes, else: state.cur_window

        seq_nr =
          if increment? do
            Packet.seq_add(seq, 1)
          else
            state.seq_nr
          end

        %{
          state
          | unacked: unacked,
            cur_window: cur_window,
            seq_nr: seq_nr,
            last_send_ms: now_ms()
        }

      {:error, reason} ->
        Logger.debug(
          "[utp] send_failed peer=#{inspect({state.peer_ip, state.peer_port})} type=#{type} reason=#{inspect(reason)}"
        )

        shutdown(state, reason)
    end
  end

  defp send_state_ack(state) do
    Logger.debug(
      "[utp] send_ack peer=#{inspect({state.peer_ip, state.peer_port})} ack_nr=#{state.ack_nr} seq_nr=#{state.seq_nr}"
    )

    transmit(state, @st_state, <<>>, state.seq_nr, false)
  end

  defp send_fin(state) do
    state
    |> transmit(@st_fin, <<>>, state.seq_nr, true)
    |> Map.put(:fin_sent, true)
  end

  defp check_timeouts(%{closed: true} = state), do: state

  defp check_timeouts(state) do
    now = now_ms()

    # First scan (pure): what's timed out, and is anyone past give-up? This
    # decouples the state-mutation from iteration so we back off exactly ONCE
    # per timeout event (libutp semantics) instead of doubling timeout_ms per
    # timed-out packet, and so a shutdown mid-iteration doesn't leave the
    # reduce still trying to retransmit later entries.
    {give_up, timed_out} =
      Enum.reduce(state.unacked, {nil, []}, fn
        {seq, {_payload, _sent_ms, tx_count, _bytes}}, {nil, list} when tx_count >= 10 ->
          {seq, list}

        {seq, {_payload, sent_ms, _tx_count, _bytes}}, {gu, list} ->
          if now - sent_ms >= state.timeout_ms do
            {gu, [seq | list]}
          else
            {gu, list}
          end
      end)

    cond do
      give_up != nil ->
        Logger.warning(
          "[utp] give_up seq=#{give_up} peer=#{inspect({state.peer_ip, state.peer_port})}"
        )

        shutdown(state, :too_many_retransmits)

      timed_out == [] ->
        state

      true ->
        state =
          state
          |> Map.put(:timeout_ms, min(state.timeout_ms * 2, 60_000))
          |> Map.put(:timeout_count, state.timeout_count + 1)
          |> put_led(LEDBAT.on_timeout(state.led))

        Enum.reduce(timed_out, state, fn seq, acc ->
          case Map.get(acc.unacked, seq) do
            nil ->
              acc

            {payload, _sent_ms, _tx_count, _bytes} ->
              transmit(acc, @st_data, payload, seq, false)
          end
        end)
    end
  end

  defp notify_connected_waiters(state) do
    {connected, rest} =
      Enum.split_with(state.recv_waiters, fn
        {_, :connected} -> true
        _ -> false
      end)

    Enum.each(connected, fn {from, :connected} -> GenServer.reply(from, :ok) end)
    %{state | recv_waiters: rest}
  end

  defp notify_accept_once(%{accept_notified: true} = state), do: state

  defp notify_accept_once(state) do
    UTP.Dispatcher.notify_accept(state.socket_ref, state.peer_ip, state.peer_port)
    %{state | accept_notified: true}
  end

  defp satisfy_recv_waiters(state) do
    Enum.reduce(state.recv_waiters, {state, []}, fn
      {from, len, timer_ref}, {s, rest} ->
        if byte_size(s.recv_buffer) >= len do
          Process.cancel_timer(timer_ref)
          {chunk, buffer} = take_bytes(s.recv_buffer, len)
          GenServer.reply(from, {:ok, chunk})
          {%{s | recv_buffer: buffer}, rest}
        else
          {s, rest ++ [{from, len, timer_ref}]}
        end

      other, {s, rest} ->
        {s, rest ++ [other]}
    end)
    |> then(fn {s, waiters} -> %{s | recv_waiters: waiters} end)
  end

  defp shutdown(state, reason) do
    if state.closed do
      state
    else
      if is_pid(state.owner) do
        send(state.owner, {:utp_closed, state.socket_ref})
      end

      :ok =
        UTP.Dispatcher.unregister_pair(
          state.recv_conn_id,
          state.send_conn_id,
          state.peer_ip,
          state.peer_port
        )

      Logger.debug(
        "[utp] closed peer=#{inspect({state.peer_ip, state.peer_port})} reason=#{inspect(reason)}"
      )

      # Stop ticking now, and schedule an actual GenServer stop after linger.
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      Process.send_after(self(), :stop_zombie, @linger_ms)

      %{state | closed: true, phase: :closed, timer_ref: nil}
    end
  end

  defp maybe_close_on_eof(state) do
    if state.eof_seq && map_size(state.recv_oob) == 0 &&
         state.recv_next == Packet.seq_add(state.eof_seq, 1) do
      shutdown(state, :fin)
    else
      state
    end
  end

  defp valid_conn_id?(state, %{type: @st_syn, conn_id: id}),
    do: id == state.send_conn_id or id == state.recv_conn_id

  defp valid_conn_id?(state, %{conn_id: id}), do: id == state.recv_conn_id

  defp packet_conn_id(state, @st_syn), do: state.recv_conn_id
  defp packet_conn_id(state, _), do: state.send_conn_id

  # BEP 29 selective ACK: ack_nr + 1 is the implicit hole, so bit zero
  # represents ack_nr + 2. The mask is little-bit-endian within each byte and
  # must be at least 32 bits, in multiples of 32 bits.
  defp selective_ack_extensions(%{recv_oob: recv_oob, ack_nr: ack_nr}) do
    offsets =
      recv_oob
      |> Map.keys()
      |> Enum.map(&(Packet.seq_diff(&1, ack_nr) - 2))
      |> Enum.filter(&(&1 >= 0))

    case offsets do
      [] ->
        []

      _ ->
        byte_count =
          offsets
          |> Enum.max()
          |> Kernel.+(1)
          |> then(&max(div(&1 + 31, 32) * 4, 4))

        offsets = MapSet.new(offsets)

        bitmask =
          for byte_index <- 0..(byte_count - 1), into: <<>> do
            byte =
              Enum.reduce(0..7, 0, fn bit_index, acc ->
                offset = byte_index * 8 + bit_index

                if MapSet.member?(offsets, offset) do
                  Bitwise.bor(acc, Bitwise.bsl(1, bit_index))
                else
                  acc
                end
              end)

            <<byte>>
          end

        [{:selective_ack, bitmask}]
    end
  end

  defp put_led(state, led), do: %{state | led: led}

  defp take_bytes(buffer, len) do
    <<chunk::binary-size(^len), rest::binary>> = buffer
    {chunk, rest}
  end

  defp schedule_tick(%{closed: true} = state), do: state

  defp schedule_tick(%{timer_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    %{state | timer_ref: Process.send_after(self(), :tick, @tick_ms)}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Never route outbound uTP through UTP.Dispatcher GenServer.call — that deadlocks
  # when the dial path is awaiting this connection's SYN.
  @spec send_udp_direct(port(), :inet.ip_address(), :inet.port_number(), iodata()) ::
          :ok | {:error, term()}
  defp send_udp_direct(udp_socket, ip, port, data) do
    case DHT.send_udp(ip, port, data) do
      :ok ->
        :ok

      {:error, :disabled} when is_port(udp_socket) ->
        try do
          case :gen_udp.send(udp_socket, ip, port, data) do
            :ok -> :ok
            {:error, _} = error -> error
          end
        rescue
          ArgumentError -> {:error, :badarg}
        catch
          :error, :badarg -> {:error, :badarg}
          :exit, :badarg -> {:error, :badarg}
        end

      other ->
        other
    end
  end

  @impl true
  def terminate(_reason, state) do
    unless state.closed do
      _ = shutdown(state, :terminate)
    end

    :ok
  end
end

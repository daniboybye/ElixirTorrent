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

  defstruct [
    :udp_socket,
    :peer_ip,
    :peer_port,
    :recv_conn_id,
    :send_conn_id,
    :socket_ref,
    :owner,
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
    recv_used: 0,
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
  def send_raw({:utp, pid}, data), do: GenServer.call(pid, {:send, data}, 60_000)

  @spec recv_raw(socket_ref(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv_raw({:utp, pid}, len, timeout),
    do: GenServer.call(pid, {:recv, len, timeout}, timeout + 5_000)

  @spec activate(socket_ref()) :: :ok | {:error, term()}
  def activate({:utp, pid}), do: GenServer.call(pid, :activate, 5_000)

  @doc false
  @spec take_recv_buffer(socket_ref()) :: binary()
  def take_recv_buffer({:utp, pid}), do: GenServer.call(pid, :take_recv_buffer, 5_000)

  @spec controlling_process(socket_ref(), pid()) :: :ok | {:error, term()}
  def controlling_process({:utp, pid}, owner),
    do: GenServer.call(pid, {:controlling_process, owner}, 5_000)

  @spec close(socket_ref()) :: :ok
  def close({:utp, pid}), do: GenServer.cast(pid, :close)

  @spec peername(socket_ref()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def peername({:utp, pid}), do: GenServer.call(pid, :peername)

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

    case GenServer.start_link(__MODULE__, state, []) do
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

  def handle_call(:take_recv_buffer, _from, state) do
    {buffer, state} = {state.recv_buffer, %{state | recv_buffer: <<>>}}
    {:reply, buffer, state}
  end

  def handle_call({:controlling_process, owner}, _from, state) when is_pid(owner) do
    {:reply, :ok, %{state | owner: owner}}
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
      timer_ref = Process.send_after(self(), {:recv_timeout, from}, timeout)
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

      {state, prev_ack} = {state, state.last_peer_ack}
      state = process_acks(state, header, extensions)

      state =
        if header.ack_nr == prev_ack do
          %{state | dup_acks: state.dup_acks + 1}
        else
          %{state | dup_acks: 0, last_peer_ack: header.ack_nr}
        end

      case header.type do
        @st_reset -> shutdown(state, :reset)
        @st_state -> handle_state_packet(state, header)
        @st_data -> handle_data_packet(state, header, payload)
        @st_fin -> handle_fin_packet(state, header, payload)
        @st_syn ->
          cond do
            state.role == :server and state.phase == :syn_recv ->
              handle_syn_server(state, header)

            state.role == :client and state.phase == :syn_sent ->
              handle_state_packet(state, header)

            true ->
              state
          end

        _ -> state
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
        %{state | recv_oob: recv_oob, recv_used: state.recv_used + byte_size(payload)}

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
    state = %{state | recv_buffer: state.recv_buffer <> payload, recv_used: state.recv_used + byte_size(payload)}

    Logger.info(
      "[utp] recv_data peer=#{inspect({state.peer_ip, state.peer_port})} bytes=#{byte_size(payload)} buffer=#{byte_size(state.recv_buffer)} waiters=#{recv_byte_waiters(state)}"
    )

    if state.active and is_pid(state.owner) do
      send(state.owner, {:utp, state.socket_ref, payload})
      state
    else
      satisfy_recv_waiters(state)
    end
  end

  defp recv_byte_waiters(state) do
    state.recv_waiters
    |> Enum.count(fn
      {_, len, _} when is_integer(len) -> true
      _ -> false
    end)
  end

  defp process_acks(state, header, extensions) do
    state = ack_in_flight_through(state, header.ack_nr)

    state =
      header
      |> Packet.selective_ack_acks(extensions)
      |> Enum.reduce(state, fn seq, acc -> ack_exact_seq(acc, seq) end)

    if map_size(state.unacked) > 0 and header.ack_nr == state.last_peer_ack and state.dup_acks >= 3 do
      retransmit_loss(state, Packet.seq_add(header.ack_nr, 1))
    else
      state
    end
  end

  defp ack_in_flight_through(%{unacked: unacked} = state, _peer_ack_nr)
       when map_size(unacked) == 0,
       do: state

  defp ack_in_flight_through(state, peer_ack_nr) do
    in_flight = map_size(state.unacked)
    base = Packet.seq_add(state.seq_nr, -1 - in_flight)
    acks = rem(peer_ack_nr - base + 65536, 65536)

    if acks > in_flight do
      state
    else
      ack_oldest_n(state, acks)
    end
  end

  defp ack_oldest_n(state, 0), do: state

  defp ack_oldest_n(state, n) when n > 0 do
    seq = oldest_unacked_seq(state)
    state = ack_exact_seq(state, seq)
    ack_oldest_n(state, n - 1)
  end

  defp oldest_unacked_seq(%{seq_nr: seq_nr, unacked: unacked}) do
    in_flight = map_size(unacked)
    first = Packet.seq_add(seq_nr, -in_flight)

    unacked
    |> Map.keys()
    |> Enum.min_by(fn seq -> rem(seq - first + 65536, 65536) end)
  end

  defp ack_exact_seq(state, seq) do
    case Map.pop(state.unacked, seq) do
      {nil, _} ->
        state

      {{_payload, sent_ms, tx_count, bytes}, unacked} ->
        Logger.info(
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
      {payload, _sent_ms, tx_count, bytes} ->
        state = put_led(state, LEDBAT.on_loss(state.led))
        entry = {payload, now_ms(), tx_count + 1, bytes}
        state = %{state | unacked: Map.put(state.unacked, seq, entry)}
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

  defp transmit(state, type, payload, seq, increment?) do
    increment? = increment? and type != @st_state

    header = %Packet{
      type: type,
      version: 1,
      extension: 0,
      conn_id: packet_conn_id(state, type),
      timestamp: rem(:os.system_time(:microsecond), 0x1_0000_0000),
      timestamp_difference: state.reply_micro,
      wnd_size: max(@recv_buffer_max - state.recv_used, 0),
      seq_nr: seq,
      ack_nr: state.ack_nr
    }

    wire = Packet.encode(header, payload)
    :ok = send_udp_direct(state.udp_socket, state.peer_ip, state.peer_port, wire)

    if type == @st_data and byte_size(payload) > 0 do
      Logger.info(
        "[utp] sent_data peer=#{inspect({state.peer_ip, state.peer_port})} seq=#{seq} bytes=#{byte_size(payload)} ack=#{state.ack_nr}"
      )
    end

    bytes = byte_size(payload)

    unacked =
      if type in [@st_data, @st_fin] do
        Map.put(state.unacked, seq, {payload, now_ms(), 1, bytes})
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

    %{state | unacked: unacked, cur_window: cur_window, seq_nr: seq_nr, last_send_ms: now_ms()}
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

  defp check_timeouts(state) do
    now = now_ms()

    Enum.reduce(state.unacked, state, fn {seq, {payload, sent_ms, tx_count, _bytes}}, acc ->
      cond do
        tx_count >= 10 ->
          Logger.warning(
            "[utp] give_up seq=#{seq} peer=#{inspect({acc.peer_ip, acc.peer_port})} tx=#{tx_count}"
          )

          shutdown(acc, :too_many_retransmits)

        now - sent_ms >= acc.timeout_ms ->
          acc =
            acc
            |> Map.put(:timeout_ms, min(acc.timeout_ms * 2, 60_000))
            |> Map.put(:timeout_count, acc.timeout_count + 1)
            |> put_led(LEDBAT.on_timeout(acc.led))

          transmit(acc, @st_data, payload, seq, false)

        true ->
          acc
      end
    end)
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

      :ok = UTP.Dispatcher.unregister_pair(state.recv_conn_id, state.send_conn_id, state.peer_ip, state.peer_port)

      Logger.debug(
        "[utp] closed peer=#{inspect({state.peer_ip, state.peer_port})} reason=#{inspect(reason)}"
      )

      %{state | closed: true, phase: :closed}
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

  defp put_led(state, led), do: %{state | led: led}

  defp take_bytes(buffer, len) do
    <<chunk::binary-size(^len), rest::binary>> = buffer
    {chunk, rest}
  end

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
    UTP.Dispatcher.send_udp(udp_socket, ip, port, data)
  end

  @impl true
  def terminate(_reason, state) do
    unless state.closed do
      _ = shutdown(state, :terminate)
    end

    :ok
  end
end

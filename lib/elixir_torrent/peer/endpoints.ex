defmodule Peer.Endpoints do
  @moduledoc false

  use GenServer

  require Logger

  alias Torrent.Swarm

  @table :elixir_torrent_peer_endpoints
  # A peer that completes the handshake but drops within this window is churn:
  # it isn't useful right now (often a seeder-to-seeder pair with nothing to
  # trade), so back it off to break the connect→drop→re-dial reconnect loop.
  @churn_threshold_ms 30_000

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(Torrent.hash(), :inet.ip_address(), :inet.port_number(), pid()) :: :ok
  def register(hash, ip, port, pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register, hash, ip, port, pid})
  catch
    :exit, _ -> :ok
  end

  @spec registered?(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: boolean()
  def registered?(hash, ip, port) do
    GenServer.call(__MODULE__, {:registered?, hash, ip, port})
  catch
    :exit, _ -> false
  end

  @spec count(Torrent.hash()) :: non_neg_integer()
  def count(hash) do
    GenServer.call(__MODULE__, {:count, hash})
  catch
    :exit, _ -> 0
  end

  @spec get_pid(Torrent.hash(), :inet.ip_address(), :inet.port_number()) :: pid() | nil
  def get_pid(hash, ip, port) do
    GenServer.call(__MODULE__, {:get_pid, hash, ip, port})
  catch
    :exit, _ -> nil
  end

  @spec list(Torrent.hash()) :: [{:inet.ip_address(), :inet.port_number()}]
  def list(hash) do
    GenServer.call(__MODULE__, {:list, hash})
  catch
    :exit, _ -> []
  end

  @impl true
  def init(_) do
    table = :ets.new(@table, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call(
        {:register, hash, ip, port, pid},
        _,
        %{table: table, monitors: monitors} = state
      ) do
    key = endpoint_key(hash, ip, port)

    monitors =
      case :ets.lookup(table, key) do
        [{^key, old_pid}] when old_pid != pid and is_pid(old_pid) ->
          if Process.alive?(old_pid), do: Peer.disconnect(old_pid)
          drop_monitors_for_key(monitors, key)

        _ ->
          monitors
      end

    ref = Process.monitor(pid)
    :ets.insert(table, {key, pid})
    now = System.monotonic_time(:millisecond)
    {:reply, :ok, %{state | monitors: Map.put(monitors, ref, {key, now})}}
  end

  def handle_call({:registered?, hash, ip, port}, _, %{table: table} = state) do
    key = endpoint_key(hash, ip, port)

    reply =
      case :ets.lookup(table, key) do
        [{^key, pid}] when is_pid(pid) ->
          Process.alive?(pid)

        _ ->
          false
      end

    {:reply, reply, state}
  end

  def handle_call({:count, hash}, _, %{table: table} = state) do
    count =
      table
      |> :ets.match({{hash, :_, :_}, :_})
      |> length()

    {:reply, count, state}
  end

  def handle_call({:get_pid, hash, ip, port}, _, %{table: table} = state) do
    key = endpoint_key(hash, ip, port)

    reply =
      case :ets.lookup(table, key) do
        [{^key, pid}] when is_pid(pid) ->
          if Process.alive?(pid), do: pid, else: nil

        _ ->
          nil
      end

    {:reply, reply, state}
  end

  def handle_call({:list, hash}, _, %{table: table} = state) do
    # :ets.match/2 returns [[ip, port], ...] — not [{ip, port}, pid].
    endpoints =
      table
      |> :ets.match({{hash, :"$1", :"$2"}, :_})
      |> Enum.map(fn [ip, port] -> {ip, port} end)

    {:reply, endpoints, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{key, connected_at}, monitors} ->
        :ets.delete(state.table, key)
        maybe_backoff_churn(key, connected_at)
        log_disconnect(key, reason)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  # Break the reconnect loop: a peer that dropped almost immediately after
  # connecting gets a dial backoff so we stop re-dialing it every few seconds.
  @spec maybe_backoff_churn({Torrent.hash(), :inet.ip_address(), :inet.port_number()}, integer()) ::
          :ok
  defp maybe_backoff_churn({hash, ip, port}, connected_at) do
    if System.monotonic_time(:millisecond) - connected_at < @churn_threshold_ms do
      Peer.DialBackoff.record(hash, ip, port, :churn)
    else
      :ok
    end
  end

  @spec endpoint_key(Torrent.hash(), :inet.ip_address(), :inet.port_number()) ::
          {Torrent.hash(), :inet.ip_address(), :inet.port_number()}
  defp endpoint_key(hash, ip, port), do: {hash, ip, port}

  @spec drop_monitors_for_key(map(), term()) :: map()
  defp drop_monitors_for_key(monitors, key) do
    Enum.reduce(monitors, %{}, fn
      {_ref, {^key, _at}}, acc -> acc
      {ref, other}, acc -> Map.put(acc, ref, other)
    end)
  end

  @spec log_disconnect({Torrent.hash(), :inet.ip_address(), :inet.port_number()}, term()) :: :ok
  defp log_disconnect({_hash, _ip, _port}, :normal), do: :ok

  defp log_disconnect({hash, ip, port}, reason) do
    active = Swarm.count(hash)

    Logger.info(
      "peer disconnected hash=#{Torrent.hex_encoded_hash(hash)} endpoint=#{inspect(ip)}:#{port} reason=#{inspect(reason)} active=#{active}"
    )
  end
end

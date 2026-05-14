defmodule NAT.PortMapper do
  @moduledoc false

  use GenServer

  require Logger

  @refresh_ms 45 * 60 * 1_000
  @retry_base_ms 60_000
  @lease_seconds 7200
  @startup_delay_ms 2_000
  @nat_detect_delay_ms 3_000
  @min_mapped 2
  # Per-method give-up: after this many consecutive full failures of a method
  # (both TCP and UDP fail on the same attempt), stop trying it for the rest
  # of the process lifetime. On this host natpmp times out on every request
  # (router has no NAT-PMP support) — retrying it every 45 min wastes 4s per
  # cycle. Under CGNAT both methods are usually inert; giving up quiets logs
  # and stops the pointless work.
  @method_max_failures 5

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :map_ports, @startup_delay_ms)
    # NAT-type detection is one-shot: mapping behaviour is a stable property of
    # the NAT, so we classify it once shortly after boot and log the verdict.
    Process.send_after(self(), :detect_nat_type, @startup_delay_ms + @nat_detect_delay_ms)

    {:ok,
     %{
       failures: 0,
       method_failures: %{natpmp: 0, upnp: 0},
       dead_methods: MapSet.new()
     }}
  end

  @impl GenServer
  def handle_info(:detect_nat_type, state) do
    # STUN queries block up to a few seconds each; keep them off the GenServer.
    Task.start(&log_nat_type/0)
    {:noreply, state}
  end

  def handle_info(:map_ports, %{failures: failures, dead_methods: dead} = state) do
    port = Acceptor.port()
    gateway = NAT.NATPMP.default_gateway()
    local_ip = Acceptor.primary_ips().inet || Acceptor.ip()

    Logger.debug(
      "[nat] mapping attempt port=#{port} local_ip=#{inspect(local_ip)} gateway=#{inspect(gateway)} skip=#{inspect(MapSet.to_list(dead))}"
    )

    summary = map_all(port, dead)
    mapped = mapped_count(summary)
    log_summary(summary, port, dead)

    {method_failures, dead} = update_method_state(state, summary)

    {failures, next_ms} =
      cond do
        mapped >= @min_mapped ->
          {0, @refresh_ms}

        # All viable methods are dead — nothing more we can do this run. Sleep
        # a full refresh interval (still keeps the timer alive in case ports
        # get manually opened / a NAT-PMP-capable router replaces the current
        # one and the process is restarted).
        all_methods_dead?(dead) ->
          Logger.debug("[nat] all_methods_dead — sleeping until next refresh")
          {0, @refresh_ms}

        true ->
          failures = failures + 1
          {failures, retry_delay_ms(failures)}
      end

    if mapped < @min_mapped and not all_methods_dead?(dead) do
      Logger.debug("[nat] retry_scheduled failures=#{failures} delay_ms=#{next_ms}")
    end

    Process.send_after(self(), :map_ports, next_ms)

    {:noreply,
     %{state | failures: failures, method_failures: method_failures, dead_methods: dead}}
  end

  @spec log_nat_type() :: :ok
  defp log_nat_type do
    case NAT.Stun.detect() do
      {:ok, mapping, reflexives} ->
        # Cache for the hole-punch initiator's symmetric-NAT guard (BEP 55)
        # and for the self-endpoint filter (rejects peers whose (ip, port)
        # matches our external reflexive address).
        NAT.Stun.put_mapping(mapping)
        NAT.Stun.put_reflexives(reflexives)

        addrs =
          reflexives
          |> Enum.map_join(",", fn {ip, port} -> "#{Acceptor.format_ip(ip)}:#{port}" end)

        Logger.info(
          "[nat] stun mapping=#{mapping} hole_punch_viable=#{mapping == :endpoint_independent} reflexive=#{addrs}"
        )

      {:error, reason} ->
        Logger.info("[nat] stun detection unavailable reason=#{inspect(reason)}")
    end

    :ok
  end

  defp map_all(port, dead) do
    natpmp =
      if MapSet.member?(dead, :natpmp) do
        %{tcp: :skipped, udp: :skipped}
      else
        %{tcp: map_natpmp(port, :tcp), udp: map_natpmp(port, :udp)}
      end

    upnp =
      if MapSet.member?(dead, :upnp) do
        %{tcp: :skipped, udp: :skipped}
      else
        discover_upnp_mappings(port)
      end

    %{
      natpmp_tcp: natpmp.tcp,
      natpmp_udp: natpmp.udp,
      upnp_tcp: upnp.tcp,
      upnp_udp: upnp.udp
    }
  end

  @spec discover_upnp_mappings(:inet.port_number()) :: %{
          tcp: term(),
          udp: term()
        }
  defp discover_upnp_mappings(port) do
    case NAT.UPnP.discover_control_url() do
      {:ok, {control_url, service_type}} ->
        external_ip = upnp_external_ip(control_url, service_type)

        %{
          tcp: map_upnp(control_url, service_type, port, :tcp, external_ip),
          udp: map_upnp(control_url, service_type, port, :udp, external_ip)
        }

      {:error, reason} ->
        Logger.debug("[nat] failed via=upnp reason=#{inspect(reason)}")
        %{tcp: {:error, reason}, udp: {:error, reason}}
    end
  end

  @spec upnp_external_ip(String.t(), String.t()) :: String.t() | nil
  defp upnp_external_ip(control_url, service_type) do
    case NAT.UPnP.get_external_ip(control_url, service_type) do
      {:ok, ip} ->
        Logger.debug("[nat] upnp external_ip=#{ip}")
        ip

      {:error, reason} ->
        Logger.debug("[nat] upnp external_ip unavailable reason=#{inspect(reason)}")
        nil
    end
  end

  @doc false
  @spec method_max_failures() :: pos_integer()
  def method_max_failures, do: @method_max_failures

  # Per-method give-up state machine. A method (natpmp / upnp) counts a failure
  # when BOTH its TCP and UDP outcomes are non-ok on this attempt; any single
  # ok resets its counter. Once a method hits @method_max_failures it moves to
  # dead_methods and stays skipped for the process lifetime (a real router
  # change means a relaunch, which resets the state).
  @doc false
  @spec update_method_state(map(), map()) :: {%{atom() => non_neg_integer()}, MapSet.t()}
  def update_method_state(%{method_failures: mf, dead_methods: dead}, summary) do
    Enum.reduce([:natpmp, :upnp], {mf, dead}, fn method, acc ->
      apply_method_failure_update(method, summary, acc)
    end)
  end

  @spec apply_method_failure_update(
          :natpmp | :upnp,
          map(),
          {%{atom() => non_neg_integer()}, MapSet.t()}
        ) :: {%{atom() => non_neg_integer()}, MapSet.t()}
  defp apply_method_failure_update(method, summary, {mf_acc, dead_acc}) do
    cond do
      MapSet.member?(dead_acc, method) ->
        {mf_acc, dead_acc}

      method_ok?(summary, method) ->
        {Map.put(mf_acc, method, 0), dead_acc}

      true ->
        bump_method_failure(mf_acc, dead_acc, method)
    end
  end

  @spec bump_method_failure(
          %{atom() => non_neg_integer()},
          MapSet.t(),
          :natpmp | :upnp
        ) :: {%{atom() => non_neg_integer()}, MapSet.t()}
  defp bump_method_failure(mf_acc, dead_acc, method) do
    n = Map.fetch!(mf_acc, method) + 1

    if n >= @method_max_failures do
      Logger.warning("[nat] give_up method=#{method} after=#{n} consecutive failures")
      {Map.put(mf_acc, method, n), MapSet.put(dead_acc, method)}
    else
      {Map.put(mf_acc, method, n), dead_acc}
    end
  end

  @spec method_ok?(map(), :natpmp | :upnp) :: boolean()
  defp method_ok?(summary, :natpmp), do: summary.natpmp_tcp == :ok or summary.natpmp_udp == :ok
  defp method_ok?(summary, :upnp), do: summary.upnp_tcp == :ok or summary.upnp_udp == :ok

  @spec all_methods_dead?(MapSet.t()) :: boolean()
  defp all_methods_dead?(dead), do: MapSet.member?(dead, :natpmp) and MapSet.member?(dead, :upnp)

  defp map_natpmp(port, proto) do
    case NAT.NATPMP.default_gateway() do
      nil ->
        Logger.debug("[nat] failed proto=#{proto} port=#{port} via=natpmp reason=no_gateway")
        :no_gateway

      gateway ->
        case NAT.NATPMP.map_port(gateway, proto, port, @lease_seconds) do
          {:ok, external, lifetime} ->
            Logger.debug(
              "[nat] mapped proto=#{proto} external_port=#{external} internal_port=#{port} lifetime=#{lifetime}s via=natpmp"
            )

            :ok

          {:error, reason} ->
            Logger.debug(
              "[nat] failed proto=#{proto} port=#{port} via=natpmp reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp map_upnp(control_url, service_type, port, proto, external_ip) do
    case NAT.UPnP.add_port_mapping(control_url, service_type, proto, port, @lease_seconds) do
      :ok ->
        Logger.debug(
          "[nat] mapped proto=#{proto} external_port=#{port} internal_port=#{port} external_ip=#{external_ip || "unknown"} via=upnp"
        )

        :ok

      {:error, :upnp_rejected} ->
        Logger.debug(
          "[nat] upnp_rejected proto=#{proto} port=#{port}; deleting stale mapping and retrying"
        )

        _ = NAT.UPnP.delete_port_mapping(control_url, service_type, proto, port)

        case NAT.UPnP.add_port_mapping(control_url, service_type, proto, port, @lease_seconds) do
          :ok ->
            Logger.debug(
              "[nat] mapped proto=#{proto} external_port=#{port} internal_port=#{port} external_ip=#{external_ip || "unknown"} via=upnp after_retry"
            )

            :ok

          {:error, reason} ->
            Logger.debug(
              "[nat] failed proto=#{proto} port=#{port} via=upnp reason=#{inspect(reason)} after_retry"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.debug(
          "[nat] failed proto=#{proto} port=#{port} via=upnp reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @spec mapped_count(map()) :: non_neg_integer()
  defp mapped_count(summary) do
    Enum.count(summary, fn
      {_k, :ok} -> true
      _ -> false
    end)
  end

  @spec retry_delay_ms(pos_integer()) :: pos_integer()
  defp retry_delay_ms(failures) when failures > 0 do
    min(@retry_base_ms * Integer.pow(2, failures - 1), @refresh_ms)
  end

  defp log_summary(summary, port, dead) do
    mapped = mapped_count(summary)
    active_slots = 4 - Enum.count(dead) * 2

    Logger.debug(
      "[nat] summary port=#{port} mapped=#{mapped}/#{active_slots} natpmp_tcp=#{tag(summary.natpmp_tcp)} natpmp_udp=#{tag(summary.natpmp_udp)} upnp_tcp=#{tag(summary.upnp_tcp)} upnp_udp=#{tag(summary.upnp_udp)}"
    )
  end

  defp tag(:ok), do: "ok"
  defp tag(:no_gateway), do: "no_gateway"
  defp tag(:skipped), do: "skipped"
  defp tag({:error, reason}), do: "failed(#{inspect(reason)})"
  defp tag(_), do: "unknown"
end

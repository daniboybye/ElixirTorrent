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

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :map_ports, @startup_delay_ms)
    # NAT-type detection is one-shot: mapping behaviour is a stable property of
    # the NAT, so we classify it once shortly after boot and log the verdict.
    Process.send_after(self(), :detect_nat_type, @startup_delay_ms + @nat_detect_delay_ms)
    {:ok, %{failures: 0}}
  end

  @impl true
  def handle_info(:detect_nat_type, state) do
    # STUN queries block up to a few seconds each; keep them off the GenServer.
    Task.start(&log_nat_type/0)
    {:noreply, state}
  end

  def handle_info(:map_ports, %{failures: failures} = state) do
    port = Acceptor.port()
    gateway = NAT.NATPMP.default_gateway()
    local_ip = Acceptor.primary_ips().inet || Acceptor.ip()

    Logger.info(
      "[nat] mapping attempt port=#{port} local_ip=#{inspect(local_ip)} gateway=#{inspect(gateway)}"
    )

    summary = map_all(port)
    mapped = mapped_count(summary)
    log_summary(summary, port)

    {failures, next_ms} =
      if mapped >= @min_mapped do
        {0, @refresh_ms}
      else
        failures = failures + 1
        {failures, retry_delay_ms(failures)}
      end

    if mapped < @min_mapped do
      Logger.info("[nat] retry_scheduled failures=#{failures} delay_ms=#{next_ms}")
    end

    Process.send_after(self(), :map_ports, next_ms)
    {:noreply, %{state | failures: failures}}
  end

  @spec log_nat_type() :: :ok
  defp log_nat_type do
    case NAT.Stun.detect() do
      {:ok, mapping, reflexives} ->
        # Cache for the hole-punch initiator's symmetric-NAT guard (BEP 55).
        NAT.Stun.put_mapping(mapping)

        addrs =
          reflexives
          |> Enum.map(fn {ip, port} -> "#{Acceptor.format_ip(ip)}:#{port}" end)
          |> Enum.join(",")

        Logger.info(
          "[nat] stun mapping=#{mapping} hole_punch_viable=#{mapping == :endpoint_independent} reflexive=#{addrs}"
        )

      {:error, reason} ->
        Logger.info("[nat] stun detection unavailable reason=#{inspect(reason)}")
    end

    :ok
  end

  defp map_all(port) do
    natpmp = %{tcp: map_natpmp(port, :tcp), udp: map_natpmp(port, :udp)}

    upnp =
      case NAT.UPnP.discover_control_url() do
        {:ok, {control_url, service_type}} ->
          external_ip =
            case NAT.UPnP.get_external_ip(control_url, service_type) do
              {:ok, ip} ->
                Logger.info("[nat] upnp external_ip=#{ip}")
                ip

              {:error, reason} ->
                Logger.info("[nat] upnp external_ip unavailable reason=#{inspect(reason)}")
                nil
            end

          %{
            tcp: map_upnp(control_url, service_type, port, :tcp, external_ip),
            udp: map_upnp(control_url, service_type, port, :udp, external_ip)
          }

        {:error, reason} ->
          Logger.info("[nat] failed via=upnp reason=#{inspect(reason)}")
          %{tcp: {:error, reason}, udp: {:error, reason}}
      end

    %{
      natpmp_tcp: natpmp.tcp,
      natpmp_udp: natpmp.udp,
      upnp_tcp: upnp.tcp,
      upnp_udp: upnp.udp
    }
  end

  defp map_natpmp(port, proto) do
    case NAT.NATPMP.default_gateway() do
      nil ->
        Logger.info("[nat] failed proto=#{proto} port=#{port} via=natpmp reason=no_gateway")
        :no_gateway

      gateway ->
        case NAT.NATPMP.map_port(gateway, proto, port, @lease_seconds) do
          {:ok, external, lifetime} ->
            Logger.info(
              "[nat] mapped proto=#{proto} external_port=#{external} internal_port=#{port} lifetime=#{lifetime}s via=natpmp"
            )

            :ok

          {:error, reason} ->
            Logger.info(
              "[nat] failed proto=#{proto} port=#{port} via=natpmp reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp map_upnp(control_url, service_type, port, proto, external_ip) do
    case NAT.UPnP.add_port_mapping(control_url, service_type, proto, port, @lease_seconds) do
      :ok ->
        Logger.info(
          "[nat] mapped proto=#{proto} external_port=#{port} internal_port=#{port} external_ip=#{external_ip || "unknown"} via=upnp"
        )

        :ok

      {:error, :upnp_rejected} ->
        Logger.info(
          "[nat] upnp_rejected proto=#{proto} port=#{port}; deleting stale mapping and retrying"
        )

        _ = NAT.UPnP.delete_port_mapping(control_url, service_type, proto, port)

        case NAT.UPnP.add_port_mapping(control_url, service_type, proto, port, @lease_seconds) do
          :ok ->
            Logger.info(
              "[nat] mapped proto=#{proto} external_port=#{port} internal_port=#{port} external_ip=#{external_ip || "unknown"} via=upnp after_retry"
            )

            :ok

          {:error, reason} ->
            Logger.info(
              "[nat] failed proto=#{proto} port=#{port} via=upnp reason=#{inspect(reason)} after_retry"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.info(
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

  defp log_summary(summary, port) do
    mapped = mapped_count(summary)

    Logger.info(
      "[nat] summary port=#{port} mapped=#{mapped}/4 natpmp_tcp=#{tag(summary.natpmp_tcp)} natpmp_udp=#{tag(summary.natpmp_udp)} upnp_tcp=#{tag(summary.upnp_tcp)} upnp_udp=#{tag(summary.upnp_udp)}"
    )
  end

  defp tag(:ok), do: "ok"
  defp tag(:no_gateway), do: "no_gateway"
  defp tag({:error, reason}), do: "failed(#{inspect(reason)})"
  defp tag(_), do: "unknown"
end

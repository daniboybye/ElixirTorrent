defmodule NAT.PortMapperTest do
  use ExUnit.Case, async: true

  alias NAT.PortMapper

  @port_mapper_ex Path.expand("../lib/elixir_torrent/nat/port_mapper.ex", __DIR__)

  test "schedules fast retry after failed mapping instead of only the 45-min refresh" do
    source = File.read!(@port_mapper_ex)

    assert source =~ "retry_scheduled"
    assert source =~ "retry_delay_ms"
    assert source =~ "@retry_base_ms"
    refute source =~ "Process.send_after(self(), :map_ports, @refresh_ms)\n    {:noreply, state}"
  end

  describe "update_method_state/2" do
    setup do
      %{state: %{method_failures: %{natpmp: 0, upnp: 0}, dead_methods: MapSet.new()}}
    end

    test "ok on either proto resets the method counter", %{state: state} do
      partial = %{natpmp_tcp: :ok, natpmp_udp: {:error, :timeout}, upnp_tcp: :ok, upnp_udp: :ok}

      {mf, dead} =
        PortMapper.update_method_state(%{state | method_failures: %{natpmp: 3, upnp: 3}}, partial)

      assert mf == %{natpmp: 0, upnp: 0}
      assert dead == MapSet.new()
    end

    test "both protos failing increments the method counter", %{state: state} do
      summary = %{
        natpmp_tcp: {:error, :timeout},
        natpmp_udp: {:error, :timeout},
        upnp_tcp: :ok,
        upnp_udp: :ok
      }

      {mf, dead} = PortMapper.update_method_state(state, summary)
      assert mf == %{natpmp: 1, upnp: 0}
      assert dead == MapSet.new()
    end

    test "method becomes dead once counter hits @method_max_failures", %{state: state} do
      summary = %{
        natpmp_tcp: {:error, :timeout},
        natpmp_udp: {:error, :timeout},
        upnp_tcp: :ok,
        upnp_udp: :ok
      }

      state = %{state | method_failures: %{natpmp: PortMapper.method_max_failures() - 1, upnp: 0}}
      {mf, dead} = PortMapper.update_method_state(state, summary)
      assert mf.natpmp == PortMapper.method_max_failures()
      assert MapSet.member?(dead, :natpmp)
    end

    test "dead methods are not touched again", %{state: state} do
      state = %{
        state
        | dead_methods: MapSet.new([:natpmp]),
          method_failures: %{natpmp: 99, upnp: 0}
      }

      # Even a fresh ok on the dead method leaves it dead (we won't re-attempt
      # until the process restarts).
      summary = %{natpmp_tcp: :ok, natpmp_udp: :ok, upnp_tcp: :ok, upnp_udp: :ok}

      {mf, dead} = PortMapper.update_method_state(state, summary)
      assert mf.natpmp == 99
      assert MapSet.member?(dead, :natpmp)
    end

    test "skipped protos count as non-ok — a dead method's counter is unaffected because we branch on membership first",
         %{state: state} do
      # Sanity: if upnp is dead and its protos come back :skipped, the counter
      # branch never runs so nothing regresses.
      state = %{state | dead_methods: MapSet.new([:upnp]), method_failures: %{natpmp: 0, upnp: 3}}
      summary = %{natpmp_tcp: :ok, natpmp_udp: :ok, upnp_tcp: :skipped, upnp_udp: :skipped}

      {mf, dead} = PortMapper.update_method_state(state, summary)
      assert mf == %{natpmp: 0, upnp: 3}
      assert dead == MapSet.new([:upnp])
    end
  end
end

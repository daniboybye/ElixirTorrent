defmodule NAT.PortMapperTest do
  use ExUnit.Case, async: true

  @port_mapper_ex Path.expand("../lib/elixir_torrent/nat/port_mapper.ex", __DIR__)

  test "schedules fast retry after failed mapping instead of only the 45-min refresh" do
    source = File.read!(@port_mapper_ex)

    assert source =~ "retry_scheduled"
    assert source =~ "retry_delay_ms"
    assert source =~ "@retry_base_ms"
    refute source =~ "Process.send_after(self(), :map_ports, @refresh_ms)\n    {:noreply, state}"
  end
end

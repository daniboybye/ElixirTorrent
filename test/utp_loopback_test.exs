defmodule UTPLoopbackTest do
  use ExUnit.Case, async: false

  alias UTP.Packet

  setup do
    unless Process.whereis(UTP.Dispatcher) do
      {:ok, _pid} = UTP.Dispatcher.start_link([])
    end

    :ok
  end

  test "dispatcher routes decoded packets to registered connection pid" do
    ip = {127, 0, 0, 1}
    port = 12_345
    conn_id = 99

    parent = self()

    conn =
      spawn(fn ->
        receive do
          {:utp_packet, header, payload, _extensions} ->
            send(parent, {:utp_packet, header.type, payload})
        end
      end)

    :ok = UTP.Dispatcher.register_pair(conn_id, rem(conn_id + 1, 65_536), ip, port, conn)

    header = %Packet{
      type: Packet.st_data(),
      version: 1,
      extension: 0,
      conn_id: conn_id,
      timestamp: 1,
      timestamp_difference: 0,
      wnd_size: 1000,
      seq_nr: 2,
      ack_nr: 1
    }

    bin = Packet.encode(header, <<0xAB>>)
    :ok = UTP.Dispatcher.dispatch(:dummy, ip, port, bin)

    assert_receive {:utp_packet, 0, <<0xAB>>}, 1_000
  end
end

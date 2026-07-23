defmodule UTPDispatcherShutdownTest do
  use ExUnit.Case, async: false

  setup do
    unless Process.whereis(UTP.Dispatcher) do
      {:ok, _} = UTP.Dispatcher.start_link([])
    end

    on_exit(fn ->
      if :ets.info(:utp_connections) == :undefined do
        if pid = Process.whereis(UTP.Dispatcher), do: GenServer.stop(pid)

        assert wait_for(fn -> :ets.info(:utp_connections) != :undefined end)
      end
    end)

    :ok
  end

  test "unregister is quiet when the conn-id table is already gone" do
    # Same failure mode as SIGTERM redeploy: table torn down before connections close.
    :ets.delete(:utp_connections)

    ip = {127, 0, 0, 1}
    port = 12_345

    assert :ok = UTP.Dispatcher.unregister(1, ip, port)
    assert :ok = UTP.Dispatcher.unregister_pair(1, 2, ip, port)
  end

  defp wait_for(fun, attempts \\ 50) do
    if fun.() or attempts == 0 do
      fun.()
    else
      Process.sleep(10)
      wait_for(fun, attempts - 1)
    end
  end
end

defmodule UTPDispatcherShutdownTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    on_exit(fn ->
      if :ets.info(:utp_connections) == :undefined do
        # Restart the complete application instead of manually stopping its
        # permanent Dispatcher child. A child-only restart contributes to the
        # top supervisor's restart intensity and can make it shut the whole
        # application down several tests later, depending on suite order.
        :ok = Application.stop(:elixir_torrent)
        {:ok, _} = Application.ensure_all_started(:elixir_torrent)
        assert :ets.info(:utp_connections) != :undefined
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
end

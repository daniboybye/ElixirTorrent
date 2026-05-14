defmodule Acceptor.IpCache do
  @moduledoc """
  Periodically snapshots `:inet.getifaddrs/0` into `:persistent_term`.

  DHT's `get_peers` reply path calls `Acceptor.primary_ips/0` on every request
  (both directly and via `dht_want/0` on send-side), which was hitting
  `getifaddrs` ~81×/sec on a busy node. The underlying interface list
  changes on DHCP/interface-flap timescales (minutes at fastest), so a coarse
  periodic refresh is orders of magnitude cheaper without any behavioural
  change. LSD also reuses this snapshot's multicast-capable interface
  addresses and indexes instead of making a second OS interface query.

  Cache miss (e.g. this GenServer not yet started in tests) falls back to a
  direct compute inside `Acceptor.all_global_ips/0`, so callers always get a
  correct answer.
  """

  use GenServer

  @refresh_ms 30_000

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(_) do
    refresh()
    schedule_refresh()
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    refresh()
    schedule_refresh()
    {:noreply, state}
  end

  defp refresh do
    :persistent_term.put(Acceptor.ip_cache_key(), Acceptor.compute_all_global_ips())
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)
end

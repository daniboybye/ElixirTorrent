defmodule Torrent.Swarm.Disconnect do
  @moduledoc false

  @disconnect_timeout_ms 5_000

  @spec all(Torrent.hash()) :: :ok
  def all(hash) do
    hash
    |> peer_pids()
    |> Task.async_stream(&Peer.disconnect/1,
      timeout: @disconnect_timeout_ms,
      ordered: false,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  @spec peer_pids(Torrent.hash()) :: [pid()]
  defp peer_pids(hash) do
    {:via, Registry, {Registry, {hash, Torrent.Swarm}}}
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
      _ -> []
    end)
  catch
    :exit, {:noproc, _} -> []
  end
end

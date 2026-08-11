defmodule Torrent.Uploader do
  @moduledoc """
  Task supervisor serving inbound BEP 3 `piece` uploads from disk for one torrent.
  """

  use Via

  alias Torrent.{FileHandle, Model}

  @spec child_spec(Torrent.hash()) :: Supervisor.child_spec()
  def child_spec(hash) do
    %{
      start: {Task.Supervisor, :start_link, [[max_restarts: 0, name: via(hash)]]},
      type: :supervisor,
      restart: :transient,
      id: __MODULE__
    }
  end

  @spec request(
          Torrent.hash(),
          Peer.id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length(),
          (iodata() -> any())
        ) :: DynamicSupervisor.on_start_child()
  def request(hash, peer_id, index, begin, length, callback) do
    Task.Supervisor.start_child(
      via(hash),
      fn ->
        name = {begin, length, index, peer_id, hash}
        Registry.register(Registry, name, nil)

        {:ok, block} = FileHandle.read(hash, index, begin, length)

        case deliver_callback(callback, block) do
          :cancelled -> :ok
          _ -> Model.uploaded_subpiece(hash, length)
        end
      end
    )
  end

  @spec deliver_callback((iodata() -> any()), iodata()) :: any()
  defp deliver_callback(callback, block) do
    callback.(block)
  catch
    :exit, :noproc -> :cancelled
    :exit, {:noproc, _call} -> :cancelled
  end

  @spec cancel(
          Torrent.hash(),
          Peer.id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length()
        ) :: :ok
  def cancel(hash, peer_id, index, begin, length) do
    name = {begin, length, index, peer_id, hash}

    with [{task, nil}] <- Registry.lookup(Registry, name),
         do: Task.Supervisor.terminate_child(via(hash), task)

    :ok
  end
end

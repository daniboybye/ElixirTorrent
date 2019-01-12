defmodule Torrent.Uploader do
  use Via

  alias Torrent.{FileHandle, Model}

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

        block = FileHandle.read(hash, index, begin, length).()
        callback.(block)
        Model.uploaded_subpiece(hash, length)
      end
    )
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

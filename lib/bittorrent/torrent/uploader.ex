defmodule Torrent.Uploader do
  require Via
  Via.make()

  alias Torrent.{FileHandle, Server}

  def child_spec(torrent) do
    %{
      start: {__MODULE__, :start_link, [torrent]},
      type: :supervisor,
      restart: :permanent,
      id: __MODULE__
    }
  end

  @spec start_link(Torrent.t()) :: Supervisor.on_start()
  def start_link(%Torrent{hash: hash}) do
    Task.Supervisor.start_link(name: via(hash))
  end

  @spec request(
          Torrent.hash(),
          Peer.id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length()
        ) :: DynamicSupervisor.on_start_child()
  def request(hash, peer_id, index, begin, length) do
    Task.Supervisor.start_child(
      via(hash),
      fn -> 
        name = {hash, peer_id, index, begin, length}
        Registry.register(Registry, name, self())
        
        block = FileHandle.read(hash, index, begin, length).()
        Peer.piece(hash, peer_id, index, begin, block)
        Server.uploaded(hash, length)
      
        Registry.unregister(Registry, name)
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
    name = {hash, peer_id, index, begin, length}
    
    with [{_, task} | _] <- Registry.lookup(Registry, name) do
      Task.Supervisor.terminate_child(via(hash), task)
      Registry.unregister(Registry, name)
    end
    
    :ok
  end
end

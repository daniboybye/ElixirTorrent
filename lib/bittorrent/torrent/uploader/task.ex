defmodule Torrent.Uploader.Task do
  use GenServer, restart: :temporary

  require Via
  Via.make()

  @spec start_link(
          {Torrent.hash(), Peer.peer_id(), Torrent.begin(), Torrent.index(), Torrent.length()}
        ) :: GenServer.on_start()
  def start_link(tuple) do
    GenServer.start_link(__MODULE__, tuple, name: via(tuple))
  end

  @spec cancel(
          Torrent.hash(),
          Peer.peer_id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length()
        ) :: :ok
  def cancel(hash, peer_id, index, begin, length) do
    with pid when is_pid(pid) <- GenServer.whereis(via({hash, peer_id, index, begin, length})) do
      Process.exit(pid, :normal)
    end

    :ok
  end

  def init(tuple) do
    send(self(), :start)
    {:ok, tuple}
  end

  def handle_info(:start, {hash, peer_id, index, begin, length}) do
    block = Torrent.FileHandle.read(hash, index, begin, length).()
    Peer.piece(hash, peer_id, index, begin, block)
    Torrent.Server.uploaded(hash, length)
    {:stop, :normal, nil}
  end
end

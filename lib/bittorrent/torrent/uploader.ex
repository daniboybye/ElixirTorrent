defmodule Torrent.Uploader do
  use GenServer

  require Via
  Via.make()

  @spec start_link(Torrent.Struct.t()) :: GenServer.on_start()
  def start_link(%Torrent.Struct{hash: hash}) do
    GenServer.start_link(__MODULE__, hash, name: via(hash))
  end

  @spec request(
          Torrent.hash(),
          Peer.peer_id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length()
        ) :: :ok
  def request(hash, peer_id, index, begin, length) do
    GenServer.cast(via(hash), {:request, peer_id, index, begin, length})
  end

  @spec cancel(Torrent.hash(), Peer.peer_id(), Torrent.begin(), Torrent.index(), Torrent.length()) ::
          :ok
  def cancel(hash, peer_id, index, begin, length) do
    GenServer.cast(via(hash), {:cancel, peer_id, index, begin, length})
  end

  def init(hash), do: {:ok, hash}

  def handle_cast({:request, peer_id, index, begin, length}, hash) do
    with false <- cancel?(peer_id, index, begin, length),
         block = Torrent.FileHandle.read(hash, index, begin, length),
         false <- cancel?(peer_id, index, begin, length) do
      Peer.piece(hash, peer_id, index, begin, block)
      Torrent.Server.uploaded(hash, length)
    end

    {:noreply, hash}
  end

  def handle_cast(_, hash), do: {:noreply, hash}

  defp cancel?(peer_id, index, begin, length) do
    receive do
      {:"$gen_cast", {:request, ^peer_id, ^index, ^begin, ^length}} ->
        true
    after
      0 -> false
    end
  end
end

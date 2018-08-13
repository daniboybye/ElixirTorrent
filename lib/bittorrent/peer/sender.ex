defmodule Peer.Sender do
  use GenServer

  require Via
  require Peer.Const
  require Logger

  Via.make()
  Peer.Const.message_id()

  @spec start_link({Peer.key(), Acceptor.socket()}) :: GenServer.on_start()
  def start_link({key, socket}) do
    GenServer.start_link(__MODULE__, socket, name: via(key))
  end

  @spec choke(Peer.key()) :: :ok
  def choke(key), do: GenServer.cast(via(key), :choke)

  @spec unchoke(Peer.key()) :: :ok
  def unchoke(key), do: GenServer.cast(via(key), :unchoke)

  @spec interested(Peer.key(), boolean()) :: :ok
  def interested(key, true), do: GenServer.cast(via(key), :interested)

  def interested(key, false), do: GenServer.cast(via(key), :not_interested)

  @spec have(Peer.key(), Torrent.index()) :: :ok
  def have(key, index), do: GenServer.cast(via(key), {:have, index})

  @spec bitfield(Peer.key()) :: :ok
  def bitfield({_, hash} = key) do
    GenServer.cast(via(key), {:bitfield, hash})
  end

  @spec request(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def request(key, index, begin, length) do
    GenServer.cast(via(key), {:request, index, begin, length})
  end

  @spec piece(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def piece(key, index, begin, block) do
    GenServer.cast(via(key), {:piece, index, begin, block})
  end

  @spec cancel(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def cancel(key, index, begin, length) do
    GenServer.cast(via(key), {:cancel, index, begin, length})
  end

  @spec port(Peer.key(), Acceptor.port_number()) :: :ok
  def port(key, port), do: GenServer.cast(via(key), {:port, port})

  def init(socket), do: {:ok, socket, @timeout_keeplive}

  def handle_cast(:choke, socket) do
    do_send(socket, <<@choke_id>>)
  end

  def handle_cast(:unchoke, socket) do
    do_send(socket, <<@unchoke_id>>)
  end

  def handle_cast(:interested, socket) do
    do_send(socket, <<@interested_id>>)
  end

  def handle_cast(:not_interested, socket) do
    do_send(socket, <<@not_interested_id>>)
  end

  def handle_cast({:have, index}, socket) do
    do_send(socket, <<@have_id, index::32>>)
  end

  def handle_cast({:bitfield, hash}, socket) do
    do_send(socket, <<@bitfield_id, Torrent.Bitfield.get(hash)::binary>>)
  end

  def handle_cast({:request, index, begin, length}, socket) do
    do_send(socket, <<@request_id, index::32, begin::32, length::32>>)
  end

  def handle_cast({:piece, index, begin, block}, socket) do
    do_send(socket, <<@piece_id, index::32, begin::32, block::binary>>)
  end

  def handle_cast({:cancel, index, begin, length}, socket) do
    do_send(socket, <<@cancel_id, index::32, begin::32, length::32>>)
  end

  def handle_cast({:port, port}, socket) do
    do_send(socket, <<@port_id, port::16>>)
  end

  def handle_info(:timeout, socket), do: do_send(socket, <<>>)

  defp do_send(socket, message) do
    :gen_tcp.send(socket, <<byte_size(message)::32, message::binary>>)
    {:noreply, socket, @timeout_keeplive - 10_000}
  end
end

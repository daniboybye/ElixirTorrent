defmodule Peer.Sender do
  use GenServer
  use Via
  use Peer.Const

  @timeout 100_000

  @spec start_link({Peer.id, Torrent.hash(), port()}) :: GenServer.on_start()
  def start_link({id, hash, socket}) do
    GenServer.start_link(__MODULE__, socket, name: via(Peer.make_key(hash, id)))
  end

  @spec choke(Peer.key()) :: :ok
  def choke(key), do: GenServer.cast(via(key), :choke)

  @spec unchoke(Peer.key()) :: :ok
  def unchoke(key), do: GenServer.cast(via(key), :unchoke)

  @spec interested(Peer.key()) :: :ok
  def interested(key), do: GenServer.cast(via(key), :interested)

  @spec not_interested(Peer.key()) :: :ok
  def not_interested(key), do: GenServer.cast(via(key), :not_interested)

  @spec interested(Peer.key(), boolean()) :: :ok
  def interested(key, true), do: interested(key)

  def interested(key, false), do: not_interested(key)

  @spec have(Peer.key(), Torrent.index()) :: :ok
  def have(key, index), do: GenServer.cast(via(key), {:have, index})

  @spec have_all(Peer.key()) :: :ok
  def have_all(key), do: GenServer.cast(via(key), :have_all)

  @spec have_none(Peer.key()) :: :ok
  def have_none(key), do: GenServer.cast(via(key), :have_none)

  @spec bitfield(Peer.key()) :: :ok
  def bitfield(key) do
    GenServer.cast(via(key), {:bitfield, Peer.key_to_hash(key)})
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

  @spec port(Peer.key(), :inet.port_number()) :: :ok
  def port(key, port), do: GenServer.cast(via(key), {:port, port})

  @spec suggest_piece(Peer.key(), Torrent.index()) :: :ok
  def suggest_piece(key, index) do
    GenServer.cast(via(key), {:suggest_piece, index})
  end

  @spec reject(Peer.key(), Torrent.index(), Torrent.begin(), Torrent.length()) :: :ok
  def reject(key, index, begin, length) do
    GenServer.cast(via(key), {:reject, index, begin, length})
  end

  @spec allowed_fast(Peer.key(), Torrent.index()) :: :ok
  def allowed_fast(key, index) do
    GenServer.cast(via(key), {:allowed_fast, index})
  end

  def init(socket), do: {:ok, socket, @timeout}

  def handle_cast(:choke, socket), do: do_send(socket, <<@choke_id>>)

  def handle_cast(:unchoke, socket), do: do_send(socket, <<@unchoke_id>>)

  def handle_cast(:interested, socket) do
    do_send(socket, <<@interested_id>>)
  end

  def handle_cast(:not_interested, socket) do
    do_send(socket, <<@not_interested_id>>)
  end

  def handle_cast({:have, index}, socket) do
    do_send(socket, <<@have_id, index::32>>)
  end

  def handle_cast(:have_all, socket) do
    do_send(socket, <<@have_all_id>>)
  end

  def handle_cast(:have_none, socket) do
    do_send(socket, <<@have_none_id>>)
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

  def handle_cast({:suggest_piece, index}, socket) do
    do_send(socket, <<@suggest_piece_id, index::32>>)
  end

  def handle_cast({:reject, index, begin, length}, socket) do
    do_send(socket, <<@reject_request_id, index::32, begin::32, length::32>>)
  end

  def handle_cast({:allowed_fast, index}, socket) do
    do_send(socket, <<@allowed_fast_id, index::32>>)
  end

  def handle_info(:timeout, socket), do: do_send(socket, <<>>)

  defp do_send(socket, message) do
    :gen_tcp.send(socket, <<byte_size(message)::32, message::binary>>)
    {:noreply, socket, @timeout}
  end
end

defmodule Peer do
  use Supervisor, restart: :temporary, type: :supervisor

  require Via
  Via.make()

  @type peer_id :: <<_::20>>
  #peer -> %{"peer id" => _, "port" => _, "ip" => _}
  @type peer :: %{required(binary()) => peer_id, required(binary()) => Acceptor.port_number(), required(binary()) => binary()}
  @type key :: {Peer.peer_id(), Torrent.hash()}

  @spec start_link({peer_id(), Acceptor.socket()}) :: Supervisor.on_start()
  def start_link({key, _socket} = args) do
    Supervisor.start_link(__MODULE__, args, name: via(key))
  end

  @spec get_id(pid()) :: Peer.peer_id()
  def get_id(pid) do
    [{{_,peer_id}, _} | _] = Registry.keys(Registry, pid)
    peer_id
  end

  @spec whereis(Torrent.hash(), peer_id()) :: pid() | {atom(), node()} | nil
  def whereis(hash, peer_id), do: GenServer.whereis(via({peer_id, hash}))

  @spec have(pid(), Torrent.index()) :: :ok | no_return()
  def have(pid, index) do
    [{key, _} | _] = Registry.keys(Registry, pid)
    __MODULE__.Controller.have(key, index)
  end

  @spec interested(pid(), Torrent.index()) :: :ok | no_return()
  def interested(pid, index) do
    [{key, _} | _] = Registry.keys(Registry, pid)
    __MODULE__.Controller.interested(key, index)
  end

  defdelegate request(hash,peer_id,index,begin,length), to: __MODULE__.Controller

  @spec piece(pid(), peer_id(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def piece(hash, peer_id, index, begin, block) do
    key = {peer_id, hash}
    __MODULE__.Controller.upload(key, byte_size(block))
    __MODULE__.Sender.piece(key, index, begin, block)
  end

  defdelegate cancel(hash, peer_id, index, begin, length), to: __MODULE__.Controller

  @spec reset_rank(pid()) :: :ok | no_return()
  def reset_rank(pid) do
    [{key, _} | _] = Registry.keys(Registry, pid)
    __MODULE__.Controller.reset_rank(key)
  end

  defdelegate choke(hash, peer_id), to: __MODULE__.Controller

  @spec want_unchoke(pid()) :: __MODULE__.Controller.want_unchoke_return() | no_return()
  def want_unchoke(pid) do
    [{key, _} | _] = Registry.keys(Registry, pid)
    __MODULE__.Controller.want_unchoke(key)
  end

  defdelegate unchoke(hash, peer_id), to: __MODULE__.Controller

  @spec seed(pid()) :: :ok | no_return()
  def seed(pid) do
    [{key, _} | _] = Registry.keys(Registry, pid)
    __MODULE__.Controller.seed(key)
  end

  def init({key, _socket} = args) do
    [
      {__MODULE__.Sender, args},
      {__MODULE__.Controller, key},
      {__MODULE__.Receiver, args}
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restart: 0)
  end
end

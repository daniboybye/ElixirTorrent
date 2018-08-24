defmodule Peer do
  use Supervisor, restart: :temporary, type: :supervisor

  require Via
  Via.make()

  @type peer_id :: <<_::160>>
  @type ip :: binary()
  @type key :: {Peer.peer_id(), Torrent.hash()}

  @enforce_keys [:ip, :port]
  defstruct [:ip, :port, peer_id: nil]

  @type t :: %__MODULE__{
          ip: ip(),
          port: Acceptor.port_number(),
          peer_id: peer_id() | nil
        }

  @spec start_link({peer_id(), port()}) :: Supervisor.on_start()
  def start_link({key, _socket} = args) do
    Supervisor.start_link(__MODULE__, args, name: via(key))
  end

  @spec get_id(pid()) :: Peer.peer_id() | nil
  def get_id(pid) do
    if key = get_key(pid) do
      elem(key,0)
    end
  end

  @spec get_key(pid()) :: Peer.key() | nil
  defp get_key(pid) do
    with [{key, _} | _] <- Registry.keys(Registry, pid) do
      key
    else
      _ -> 
        nil
    end
  end

  @spec whereis(Torrent.hash(), peer_id()) :: pid() | {atom(), node()} | nil
  def whereis(hash, peer_id), do: GenServer.whereis(via({peer_id, hash}))

  @spec have(pid(), Torrent.index()) :: :ok | nil
  def have(pid, index) do
    if key = get_key(pid) do
      __MODULE__.Controller.have(key, index)
    end
  end

  @spec interested(pid(), Torrent.index()) :: :ok | nil
  def interested(pid, index) do
    if key = get_key(pid) do
      __MODULE__.Controller.interested(key, index)
    end
  end

  defdelegate request(hash, peer_id, index, begin, length), to: __MODULE__.Controller

  @spec piece(Torrent.hash(), peer_id(), Torrent.index(), Torrent.begin(), Torrent.block()) :: :ok
  def piece(hash, peer_id, index, begin, block) do
    key = {peer_id, hash}
    __MODULE__.Controller.upload(key, byte_size(block))
    __MODULE__.Sender.piece(key, index, begin, block)
  end

  defdelegate cancel(hash, peer_id, index, begin, length), to: __MODULE__.Controller

  @spec reset_rank(pid()) :: :ok | nil
  def reset_rank(pid) do
    if key = get_key(pid) do
      __MODULE__.Controller.reset_rank(key)
    end
  end

  defdelegate choke(hash, peer_id), to: __MODULE__.Controller

  @spec want_unchoke(pid()) :: __MODULE__.Controller.want_unchoke_return()
  def want_unchoke(pid) do
    if key = get_key(pid) do
      __MODULE__.Controller.want_unchoke(key)
    end
  end

  defdelegate unchoke(hash, peer_id), to: __MODULE__.Controller

  @spec seed(pid()) :: :ok | nil
  def seed(pid) do
    if key = get_key(pid) do
      __MODULE__.Controller.seed(key)
    end
  end

  def init({key, _socket} = args) do
    [
      {__MODULE__.Sender, args},
      {__MODULE__.Controller, key},
      {__MODULE__.Receiver, args}
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restarts: 0)
  end
end

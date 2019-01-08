defmodule Peer do
  use Supervisor, restart: :temporary, type: :supervisor
  use Via

  alias __MODULE__.{Sender, Controller, Receiver}

  @type id :: <<_::160>>
  @type reserved :: <<_::64>>
  @type ip :: binary()
  @type key :: {id(), Torrent.hash()}
  @type status :: nil | :seed | Torrent.index()

  @reserved <<0, 0, 0, 0, 0, 0, 0, 4>>
  @id_length 20
  @id <<ElixirTorrent.version()::binary, "-",
        :crypto.strong_rand_bytes(@id_length - byte_size(ElixirTorrent.version()) - 1)::binary>>

  @enforce_keys [:ip, :port]
  defstruct [:ip, :port, id: nil]

  @type t :: %__MODULE__{
          ip: ip(),
          port: :inet.port_number(),
          id: id() | nil
        }

  @spec start_link({id(), Torrent.hash(), port(), reserved()}) :: Supervisor.on_start()
  def start_link({id, hash, _socket, _reserved} = args) do
    Supervisor.start_link(__MODULE__, args, name: via(make_key(hash, id)))
  end

  @spec id :: id()
  def id, do: @id

  @spec reserved :: reserved()
  def reserved, do: @reserved

  @spec dht?(reserved()) :: boolean()
  def dht?(<<_::63, x::1>>), do: x == 1

  @spec fast_extension?(reserved()) :: boolean()
  def fast_extension?(<<_::61, x::1, _::2>>), do: x == 1

  @spec get_id(pid()) :: Peer.id() | nil
  def get_id(pid) do
    if key = get_key(pid), do: key_to_id(key)
  end

  @spec get_key(pid()) :: Peer.key() | nil
  defp get_key(pid) do
    case Registry.keys(Registry, pid) do
      [{key, _} | _] ->
        key

      [] ->
        nil
    end
  end

  @spec whereis(Torrent.hash(), id()) :: pid() | {atom(), node()} | nil
  def whereis(hash, id) do
    hash
    |> make_key(id)
    |> via
    |> GenServer.whereis()
  end

  @spec have(pid(), Torrent.index()) :: :ok | nil
  def have(pid, index) do
    if key = get_key(pid), do: Controller.have(key, index)
  end

  @spec interested(pid(), Torrent.index()) :: :ok | nil
  def interested(pid, index) do
    if key = get_key(pid), do: Controller.interested(key, index)
  end

  # defdelegate request(hash, id, index, begin, length), to: Controller

  defdelegate piece(hash, id, index, begin, block), to: Controller

  defdelegate cancel(hash, id, index, begin, length), to: Controller

  defdelegate choke(hash, id), to: Controller

  defdelegate unchoke(hash, id), to: Controller

  @spec reset_rank(pid()) :: :ok | nil
  def reset_rank(pid) do
    if key = get_key(pid), do: Controller.reset_rank(key)
  end

  @spec rank(pid()) :: Controller.State.rank()
  def rank(pid) do
    if key = get_key(pid), do: Controller.rank(key)
  end

  @spec port(pid(), :inet.port_number()) :: :ok | nil
  def port(pid, port) do
    if key = get_key(pid), do: Sender.port(key, port)
  end

  @spec seed(pid()) :: :ok | nil
  def seed(pid) do
    if key = get_key(pid), do: Controller.seed(key)
  end

  @spec make_key(Torrent.hash(), id()) :: key()
  def make_key(hash, id), do: {id, hash}

  @spec key_to_id(key()) :: id()
  def key_to_id({id, _}), do: id

  @spec key_to_hash(key()) :: Torrent.hash()
  def key_to_hash({_, hash}), do: hash

  def init(args) do
    [
      {Sender, Tuple.delete_at(args, 3)},
      {Controller, args},
      {Receiver, Tuple.delete_at(args, 3)}
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restarts: 0)
  end
end

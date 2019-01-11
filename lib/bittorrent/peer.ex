defmodule Peer do
  @enforce_keys [:ip, :port]
  defstruct [:ip, :port, id: nil]

  @docmodule """
  Recommend Peer controls a :gen_tcp.socket 
  and do not need to be closed manually
  """

  use Via

  alias __MODULE__.{Sender, Controller, Receiver}

  def child_spec(args) do
    %{
      id: __MODULE__,
      restart: :temporary,
      type: :supervisor,
      start: {__MODULE__, :start_link, args}
    }
  end

  def start_link(hash, id, socket, reserved) do
    children = [
      {Sender, [hash, id, socket]},
      {Controller, [hash, id, socket, reserved]},
      {Receiver, [hash, id, socket]}
    ]

    opts = [name: vm(hash, id), strategy: :one_for_all, max_restarts: 0]

    Supervisor.start_link(children, opts)
  end

  @type id :: <<_::160>>
  @type reserved :: <<_::64>>
  @type ip :: binary()
  @type key :: {id(), Torrent.hash()}
  @type status :: nil | :seed | :connecting_to_peers | Torrent.index()

  @reserved <<0, 0, 0, 0, 0, 0, 0, 4>>
  @id_length 20
  @id <<ElixirTorrent.version()::binary, "-",
        :crypto.strong_rand_bytes(@id_length - byte_size(ElixirTorrent.version()) - 1)::binary>>

  @type t :: %__MODULE__{
          ip: ip(),
          port: :inet.port_number(),
          id: id() | nil
        }

  defp vm(hash, id), do: via(make_key(hash, id))

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

  @spec exists?(t(), Torrent.hash()) :: boolean()
  def exists?(%Peer{id: id}, hash), do: !!whereis(hash, id)

  @spec whereis(Torrent.hash(), id()) :: pid() | {atom(), node()} | nil
  def whereis(hash, id), do: GenServer.whereis(vm(hash, id))

  @spec have(pid(), Torrent.index()) :: :ok | nil
  def have(pid, index) do
    if key = get_key(pid), do: Controller.have(key, index)
  end

  @spec interested(pid(), Torrent.index()) :: :ok | nil
  def interested(pid, index) do
    if key = get_key(pid), do: Controller.interested(key, index)
  end

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
end

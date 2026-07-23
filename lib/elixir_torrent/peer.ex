defmodule Peer do
  @enforce_keys [:ip, :port]
  # `seed` is set from BEP 11 PEX `added.f` / `added6.f` (bit 0x02) when ingesting
  # peers for dial; nil means no PEX seed hint (tracker/DHT/LSD sources).
  defstruct [:ip, :port, id: nil, seed: nil]

  @moduledoc """
  Recommend Peer controls a :gen_tcp.socket 
  and do not need to be closed manually
  """

  use Via

  alias __MODULE__.{Sender, Controller}

  import ElixirTorrent, only: [version: 0]

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
      {Controller, [hash, id, socket, reserved]}
    ]

    opts = [name: vm(hash, id), strategy: :one_for_all, max_restarts: 0]

    Supervisor.start_link(children, opts)
  end

  @type id :: <<_::160>>
  @type reserved :: <<_::64>>
  @type ip :: :inet.ip_address()
  @type key :: {id(), Torrent.hash()}
  @type status :: nil | :seed | :connecting_to_peers | Torrent.index()

  # BEP 10 LTEP (byte 5: 0x10), BEP 5 DHT + BEP 6 Fast (byte 7: 0x05)
  @reserved <<0, 0, 0, 0, 0, 0x10, 0, 5>>
  @id_length 20
  @id version() <> "-" <> :crypto.strong_rand_bytes(@id_length - byte_size(version()) - 1)

  @type t :: %__MODULE__{
          ip: ip(),
          port: :inet.port_number(),
          id: id() | nil,
          seed: boolean() | nil
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

  @spec extension_protocol?(reserved()) :: boolean()
  defdelegate extension_protocol?(reserved), to: Peer.LTEP

  @spec get_id(pid()) :: Peer.id() | nil
  def get_id(pid) do
    if key = get_key(pid), do: key_to_id(key)
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

  @spec send_pex(pid(), binary()) :: :ok | nil
  def send_pex(pid, payload) when is_pid(pid) and is_binary(payload) do
    if key = get_key(pid), do: Controller.send_pex(key, payload)
  end

  @spec disconnect(pid()) :: :ok
  def disconnect(pid) when is_pid(pid) do
    if key = get_key(pid), do: Controller.disconnect(key), else: :ok
  end

  @doc false
  @spec sender_pid(pid()) :: pid() | nil
  def sender_pid(supervisor_pid) when is_pid(supervisor_pid) do
    child_pid(supervisor_pid, Peer.Sender)
  end

  @spec get_key(pid()) :: key() | nil
  def get_key(pid) do
    case Registry.keys(Registry, pid) do
      [{key, Peer}] -> key
      [] -> nil
    end
  end

  @spec child_pid(pid(), module()) :: pid() | nil
  defp child_pid(supervisor_pid, module) when is_pid(supervisor_pid) do
    if Process.alive?(supervisor_pid) do
      try do
        supervisor_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {^module, pid, _, _} when is_pid(pid) -> pid
          _ -> nil
        end)
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end

  @doc false
  @spec start_protocol(pid()) :: :ok | {:error, term()}
  def start_protocol(supervisor_pid) when is_pid(supervisor_pid) do
    if key = get_key(supervisor_pid) do
      Peer.Controller.start_protocol(key)
    else
      {:error, :peer_not_registered}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec make_key(Torrent.hash(), id()) :: key()
  def make_key(hash, id), do: {id, hash}

  @spec key_to_id(key()) :: id()
  def key_to_id({id, _}), do: id

  @spec key_to_hash(key()) :: Torrent.hash()
  def key_to_hash({_, hash}), do: hash

  @doc """
  Renders a peer id for logs. BitTorrent peer ids are opaque 20-byte blobs and are
  often invalid UTF-8; interpolating them into Logger messages breaks the default
  formatter with `FORMATTER ERROR: bad return value`.
  """
  @spec log_id(id() | nil) :: String.t()
  def log_id(nil), do: "?"

  def log_id(id) when is_binary(id) do
    if String.valid?(id) do
      id
    else
      Base.encode16(id, case: :lower)
    end
  end

  @spec log_key(key()) :: String.t()
  def log_key(key), do: log_id(key_to_id(key))
end

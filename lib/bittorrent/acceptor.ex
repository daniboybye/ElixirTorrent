defmodule Acceptor do
  use Supervisor, type: :supervisor, start: {__MODULE__, :start_link, []}

  alias __MODULE__.{ListenSocket, BlackList, Pool}

  @spec start_link() :: Supervisor.on_start()
  def start_link(), do: Supervisor.start_link(__MODULE__, nil)

  defdelegate port(), to: ListenSocket

  @spec socket_options() :: list()
  def socket_options(), do: [:binary, active: false, reuseaddr: true]

  @spec port_range() :: Range.t()
  def port_range(), do: 6881..9999

  @spec open_udp() :: port()
  def open_udp(), do: Enum.find_value(port_range(), &set_up/1)

  @key :math.pow(2, 32) |> trunc() |> :rand.uniform() |> Kernel.-(1)

  @spec key() :: Tracker.key()
  def key(), do: @key

  @spec ip() :: tuple()
  def ip() do
    :inet.getif()
    |> elem(1)
    |> hd()
    |> elem(0)
  end

  @spec ip_string() :: String.t()
  def ip_string() do
    ip()
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  @spec ip_binary() :: <<_::32>> | <<_::128>>
  def ip_binary() do
    ip()
    |> Tuple.to_list()
    |> :binary.list_to_bin()
  end

  @spec recv(port()) :: DynamicSupervisor.on_start_child()
  def recv(client) do
    Task.Supervisor.start_child(__MODULE__.Handshakes, Handshake, :recv, [client])
  end

  @spec send(Peer.t(), Torrent.hash()) :: DynamicSupervisor.on_start_child()
  def send(peer, hash) do
    Task.Supervisor.start_child(__MODULE__.Handshakes, Handshake, :send, [peer, hash])
  end

  def init(_) do
    [
      BlackList,
      Pool,
      {
        Task.Supervisor,
        name: __MODULE__.Handshakes, strategy: :one_for_one, max_restarts: 0
      },
      ListenSocket
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp set_up(n) do
    case :gen_udp.open(n, Acceptor.socket_options()) do
      {:ok, socket} ->
        socket

      {:error, _} ->
        nil
    end
  end
end

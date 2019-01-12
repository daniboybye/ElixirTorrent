defmodule Acceptor do
  alias __MODULE__.{BlackList, Connection}
  alias Connection.{Handshakes, Handler}

  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [[BlackList, Connection], [strategy: :one_for_one]]}
    }
  end

  defdelegate port(), to: Handler

  defdelegate malicious_peer(id), to: BlackList, as: :put

  defdelegate handshakes(peers, hash), to: Handshakes

  @spec socket_options() :: list()
  def socket_options(), do: [:binary, active: false, reuseaddr: true]

  @spec port_range() :: Range.t()
  def port_range(), do: 6881..9999

  @spec open_udp() :: port() | nil
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

  defp set_up(n) do
    case :gen_udp.open(n, Acceptor.socket_options()) do
      {:ok, socket} ->
        socket

      {:error, _} ->
        nil
    end
  end
end

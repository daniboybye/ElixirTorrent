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

  @spec socket_options(:inet | :inet6) :: list()
  def socket_options(:inet), do: socket_options() ++ [:inet]
  def socket_options(:inet6), do: socket_options() ++ [:inet6, ipv6_v6only: false]

  @spec port_range() :: Range.t()
  def port_range(), do: 6881..9999

  @spec open_udp() :: {:ok, port()} | :error
  def open_udp(), do: open_udp(:inet)

  @spec open_udp(:inet | :inet6) :: {:ok, port()} | :error
  def open_udp(family) do
    Enum.find_value(port_range(), :error, fn number ->
      with {:error, _} <- :gen_udp.open(number, socket_options(family)),
           do: nil
    end)
  end

  @key :crypto.strong_rand_bytes(4)

  @spec key() :: <<_::32>>
  def key(), do: @key

  @spec ip() :: tuple()
  def ip() do
    :inet.getif()
    |> elem(1)
    |> hd()
    |> elem(0)
  end

  end

  @spec ip_binary() :: <<_::32>> | <<_::128>>
  def ip_binary() do
    case ip() do
      {a, b, c, d} ->
        <<a, b, c, d>>

      {s1, s2, s3, s4, s5, s6, s7, s8} ->
        <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>>
    end
  end
end

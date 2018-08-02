defmodule Bittorent.Acceptor.Listen do
  use GenServer

  import Bittorent

  @doc """
  Listen controls a :gen_tcp.listen 
  and do not need to be closed manually
  """

  def start_link(), do: GenServer.start_link(__MODULE__, nil)

  def init(_) do
    PeerDiscovery.port()
    |> :gen_tcp.listen([:binary, active: false, reuseaddr: true])
    |> case do
      {:ok, _} = x ->
        send(self(), :loop)
        x

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_info(:loop, socket), do: loop(socket)

  defp loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Acceptor.recv(client)
    loop(socket)
  end
end

defmodule Bittorent.Acceptor.Listen do
  use GenServer

  import Bittorent

  def start_link() do
    GenServer.start_link(__MODULE__, :ok)
  end

  def init(:ok) do
    case :gen_tcp.listen(PeerDiscovery.port(), [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        send(self(), :loop)
        {:ok, socket}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def terminate(_, socket) do
    :gen_tcp.close(socket)
  end

  def handle_info(:loop, socket) do
    loop(socket)
  end

  defp loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Task.Supervisor.start_child(
      Accepctor.Handshakes,
      Handshake, :recv, [client,PeerDiscovery.peer_id()]
    )
    loop(socket)
  end
end

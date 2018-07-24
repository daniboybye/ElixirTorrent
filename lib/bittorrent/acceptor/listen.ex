defmodule Bittorent.Acceptor.Listen do
  use GenServer

  import Bittorent

  def start_link() do
    GenServer.start_link(__MODULE__, nil)
  end

  def init(_) do
    case :gen_tcp.listen(
      PeerDiscovery.port(), 
      [:binary, active: false, reuseaddr: true]
    ) do
      {:ok, _} = x ->
        send(self(), :loop)
        x

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def terminate(_, socket), do: :gen_tcp.close(socket)

  def handle_info(:loop, socket), do: loop(socket)

  defp loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    Task.Supervisor.start_child(
      Accepctor.Handshakes,
      Handshake, 
      :recv, 
      [client, PeerDiscovery.peer_id()]
    )
    
    loop(socket)
  end
end

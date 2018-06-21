defmodule Bittorrent.Peer.Receiver do
  use GenServer

  def init(socket) do
    case :gen_tcp.controlling_process(socket, self()) do
      :ok ->
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
  end
end

defmodule Bittorent.Acceptor.Listen do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init({port, peer_id}) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} = x ->
        send(self(), :loop)
        {:ok, {socket, peer_id}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def terminate(_, socket) do
    :gen_tcp.close(socket)
  end

  def handle_info(:loop, {socket, peer_id}) do
    loop(peer_id, socket)
  end

  defp loop(my_peer_id, socket) do
    with {:ok, client} <- :gen_tcp.accept(socket),
         {:ok,
          <<@pstrlen, @pstr, _::bytes-size(8), info_hash::bytes-size(20),
            peer_id::bytes-size(20)>>} <- :gen_tcp.recv(client, 68, 10_000),
         false <- Bittorent.Acceptor.BlackList.member?(peer_id),
         {:ok, swarm} <- Bittorrent.Registry.find_info_hash(info_hash),
         :ok <-
           :gen_tcp.send(
             client,
             <<@pstrlen, @pstr, @reserved, info_hash::binary, my_peer_id::binary>>
           ) do
      create_peer
      loop(my_peer_id, socket)
    else
      _ -> loop(my_peer_id, socket)
    end
  end
end

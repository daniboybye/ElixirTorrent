defmodule Bittorrent.Handshake do

  import Bittorent

  @pstr "BitTorrent protocol"
  @pstrlen <<byte_size(@pstr)>>
  @reserved <<0, 0, 0, 0, 0, 0, 0, 0>>

  def send(%{"ip" => ip, "port" => port, "peer id" => peer_id}, hash) do
    with {:ok, socket} <-
      :gen_tcp.connect(
        String.to_charlist(ip),
        port,
        [:binary, active: false, reuseaddr: true],
        20_000
        ) do
    message = <<@pstrlen, @pstr,@reserved,
      hash::binary,
      PeerDiscovery.peer_id()::binary>>
    :gen_tcp.send(socket, message)

    case recv(socket, byte_size(message), 20_000) do
      {:ok,
      <<@pstrlen, @pstr, _::bytes-size(8), ^hash::bytes-size(20),
        ^peer_id::bytes-size(20)>>} ->
        
        Torrent.add_peer(hash,peer_id,socket)
        :ok

      {:error, :closed} ->
        :error

      _ ->
        :gen_tcp.close(socket)
        :error
    end
    else
    _ -> :error
    end
  end

  def recv(socket) do
    with {:ok,
          <<@pstrlen, @pstr, _::bytes-size(8), hash::bytes-size(20),
            peer_id::bytes-size(20)>>} <- :gen_tcp.recv(socket, 68, 10_000),
         false <- Acceptor.BlackList.member?(peer_id),
         true <- PeerDiscovery.has_hash?(hash),
         :ok <-
           :gen_tcp.send(
             socket,
             <<@pstrlen, @pstr, @reserved,
              hash::binary, PeerDiscovery.peer_id()::binary>>
           ) 
    do
      Torrent.add_peer(hash,peer_id,socket)
      :ok
    else
    _ ->
      :gen_tcp.close(socket)
      :error
    end
  end
end
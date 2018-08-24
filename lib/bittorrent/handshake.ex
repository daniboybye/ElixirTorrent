defmodule Handshake do
  require Logger

  @pstr "BitTorrent protocol"
  @pstrlen <<byte_size(@pstr)>>
  @reserved <<0, 0, 0, 0, 0, 0, 0, 0>>

  @spec send(Peer.t(), Torrent.hash()) :: pid() | {:error, any()} | :error
  def send(%Peer{port: port, ip: ip}, hash) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(ip),
             port,
             Acceptor.socket_options(),
             120_000
           ) do
      Acceptor.Pool.give_control(socket)
      message = <<@pstrlen, @pstr, @reserved, hash::binary, PeerDiscovery.peer_id()::binary>>
      :gen_tcp.send(socket, message)

      # don't check peer_id
      with {:ok,
            <<@pstrlen, @pstr, _::bytes-size(8), ^hash::bytes-size(20), peer_id::bytes-size(20)>>} <-
             :gen_tcp.recv(socket, byte_size(message), 120_000),
           false <- Acceptor.BlackList.member?(peer_id),
           res when is_tuple(res) and elem(res, 0) == :ok <-
             Torrent.add_peer(hash, peer_id, socket) do
        elem(res, 1)
      else
        _ ->
          Acceptor.Pool.close(socket)
          :error
      end
    end
  end

  @spec recv(port()) :: pid() | :error
  def recv(socket) do
    with {:ok,
          <<@pstrlen, @pstr, _::bytes-size(8), hash::bytes-size(20), peer_id::bytes-size(20)>>} <-
           :gen_tcp.recv(socket, 68, 120_000),
         false <- Acceptor.BlackList.member?(peer_id),
         true <- Torrent.has_hash?(hash),
         :ok <-
           :gen_tcp.send(
             socket,
             <<@pstrlen, @pstr, @reserved, hash::binary, PeerDiscovery.peer_id()::binary>>
           ),
         res when is_tuple(res) and elem(res, 0) == :ok <- Torrent.add_peer(hash, peer_id, socket) do
      elem(res, 1)
    else
      _ ->
        Acceptor.Pool.close(socket)
        :error
    end
  end
end

defmodule Handshake do
  require Logger

  @pstr "BitTorrent protocol"
  @pstrlen <<byte_size(@pstr)>>
  @reserved <<0, 0, 0, 0, 0, 0, 0, 0>>

  @doc """
  return true => peer is blacklisted
  """
  @spec send(peer :: Peer.peer(), hash :: Torrent.hash()) ::
          pid() | {:error, any()} | :error | true
  def send(%{"ip" => ip, "port" => port, "peer id" => peer_id}, hash) do
    with false <- Acceptor.BlackList.member?(peer_id),
         {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(ip),
             port,
             Acceptor.socket_options(),
             20_000
           ) do
      Acceptor.Pool.give_control(socket)
      message = <<@pstrlen, @pstr, @reserved, hash::binary, PeerDiscovery.peer_id()::binary>>
      :gen_tcp.send(socket, message)

      with {:ok,
            <<@pstrlen, @pstr, _::bytes-size(8), ^hash::bytes-size(20), ^peer_id::bytes-size(20)>>} <-
             :gen_tcp.recv(socket, byte_size(message), 20_000),
           res when is_tuple(res) and elem(res, 0) == :ok <-
             Torrent.add_peer(hash, peer_id, socket) do
        elem(res, 1)
      else
        #{:ok, <<@pstrlen, @pstr, _::bytes-size(8), ^hash::bytes-size(20), id::bytes-size(20)>>} ->
        #  Logger.info "peer id not match"
        #  IO.inspect(id,label: "before")
        #  IO.inspect(peer_id,label: "after") 
        _ ->
          Acceptor.Pool.close(socket)
          :error
      end
    end
  end

  @spec recv(socket :: Acceptor.socket()) :: pid() | :error
  def recv(socket) do
    with {:ok,
          <<@pstrlen, @pstr, _::bytes-size(8), hash::bytes-size(20), peer_id::bytes-size(20)>>} <-
           :gen_tcp.recv(socket, 68, 10_000),
         false <- Acceptor.BlackList.member?(peer_id),
         true <- PeerDiscovery.has_hash?(hash),
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

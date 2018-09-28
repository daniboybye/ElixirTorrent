defmodule Handshake do
  require Logger

  @pstr "BitTorrent protocol"
  @pstrlen byte_size(@pstr)

  alias Acceptor.{Pool, BlackList}

  @spec send(Peer.t(), Torrent.hash()) :: pid() | {:error, any()} | :error
  def send(%Peer{port: port, ip: ip}, hash) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(ip),
             port,
             Acceptor.socket_options(),
             120_000
           ) do
      Pool.give_control(socket)

      message = message(hash)

      with :ok <- :gen_tcp.send(socket, message),
           {:ok,
            <<@pstrlen, @pstr, reserved::bytes-size(8), ^hash::bytes-size(20),
              peer_id::bytes-size(20)>>} <- :gen_tcp.recv(socket, byte_size(message), 120_000),
           false <- BlackList.member?(peer_id),
           {:ok, pid} <- Torrent.add_peer(hash, peer_id, reserved, socket) do
        pid
      else
        _ ->
          Pool.close(socket)
          :error
      end
    end
  end

  @spec recv(port()) :: pid() | :error
  def recv(socket) do
    with {:ok,
          <<@pstrlen, @pstr, reserved::bytes-size(8), hash::bytes-size(20),
            peer_id::bytes-size(20)>>} <- :gen_tcp.recv(socket, 68, 120_000),
         false <- BlackList.member?(peer_id),
         true <- Torrent.has_hash?(hash),
         :ok <-
           :gen_tcp.send(
             socket,
             message(hash)
           ),
         {:ok, pid} <- Torrent.add_peer(hash, peer_id, reserved, socket) do
      pid
    else
      _ ->
        Pool.close(socket)
        :error
    end
  end

  @spec message(Torrent.hash()) :: <<_::544>>
  defp message(hash) do
    <<@pstrlen, @pstr, Peer.reserved()::binary, hash::binary, Peer.id()::binary>>
  end
end

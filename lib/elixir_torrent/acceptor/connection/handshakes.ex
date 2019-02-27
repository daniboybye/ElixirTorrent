defmodule Acceptor.Connection.Handshakes do
  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Task.Supervisor, :start_link,
         [[name: __MODULE__, strategy: :one_for_one, max_restarts: 0]]}
    }
  end

  def recv(socket) do
    case start_task(fn -> do_recv(socket) end) do
      {:ok, pid} ->
        :ok = :gen_tcp.controlling_process(socket, pid)

      {:ok, pid, _} ->
        :ok = :gen_tcp.controlling_process(socket, pid)

      _ ->
        :ok
    end
  end

  @spec handshakes(list(Peer.t()), Torrent.hash()) :: :ok
  def handshakes(peers, hash),
    do: Enum.each(peers, &start_task(fn -> do_send(&1, hash) end))

  @pstr "BitTorrent protocol"
  @pstrlen <<byte_size(@pstr)>>
  @msg_length 68
  @timeout 2 * 60 * 1_000

  alias Acceptor.BlackList

  defp start_task(fun),
    do: Task.Supervisor.start_child(__MODULE__, fun)

  @spec do_send(Peer.t(), Torrent.hash()) :: :ok | any()
  defp do_send(%Peer{} = peer, hash) do
    with false <- Peer.exists?(peer, hash),
         ip = String.to_charlist(peer.ip),
         opts = Acceptor.socket_options(),
         {:ok, socket} <- :gen_tcp.connect(ip, peer.port, opts, @timeout),
         :ok <- send_msg(socket, hash),
         {^hash, peer_id, reserved} <- recv_msg(socket),
         false <- BlackList.member?(peer_id),
         :ok <- add_peer(hash, peer_id, reserved, socket),
         do: :ok
  end

  @spec do_recv(port()) :: :ok | any()
  defp do_recv(socket) do
    with {hash, peer_id, reserved} <- recv_msg(socket),
         false <- BlackList.member?(peer_id),
         true <- Torrent.has_hash?(hash),
         :ok <- send_msg(socket, hash),
         :ok <- add_peer(hash, peer_id, reserved, socket),
         do: :ok
  end

  defp add_peer(hash, peer_id, reserved, socket) do
    case Torrent.add_peer(hash, peer_id, reserved, socket) do
      {:ok, pid} ->
        :gen_tcp.controlling_process(socket, pid)

      {:ok, pid, _} ->
        :gen_tcp.controlling_process(socket, pid)

      _ ->
        :ok
    end
  end

  defp send_msg(socket, hash) do
    msg = [@pstrlen, @pstr, Peer.reserved(), hash, Peer.id()]
    :gen_tcp.send(socket, msg)
  end

  defp recv_msg(socket) do
    with {:ok,
          <<@pstrlen, @pstr, reserved::bytes-size(8), hash::bytes-size(20),
            peer_id::bytes-size(20)>>} <- :gen_tcp.recv(socket, @msg_length, @timeout),
         do: {hash, peer_id, reserved}
  end
end

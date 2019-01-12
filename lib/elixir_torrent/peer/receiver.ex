defmodule Peer.Receiver do
  use Task, restart: :permanent
  use Peer.Const

  require Logger

  import Peer.Controller

  @max_length Torrent.Downloads.piece_max_length()

  def start_link(args), do: Task.start_link(__MODULE__, :run, args)

  def run(hash, id, socket) do
    case reason = loop(socket, Peer.make_key(hash, id)) do
      :protocol_error ->
        Acceptor.malicious_peer(id)

      {:error, x} ->
        x
    end

    {:shutdown, reason}
  end

  defp recv_msg(_, 0), do: {:ok, <<>>}

  defp recv_msg(socket, len),
    do: :gen_tcp.recv(socket, len, 120_000)

  defp loop(socket, key) do
    with {:ok, <<len::32>>} <- :gen_tcp.recv(socket, 4, 120_000),
         {:ok, message} <- recv_msg(socket, len),
         :ok <- parse(message, key),
         do: loop(socket, key)
  end

  defp parse(<<>>, _), do: :ok

  defp parse(@choke_id, key), do: handle_choke(key)

  defp parse(@unchoke_id, key), do: handle_unchoke(key)

  defp parse(@interested_id, key), do: handle_interested(key)

  defp parse(@not_interested_id, key),
    do: handle_not_interested(key)

  defp parse(<<@have_id, index::32>>, key),
    do: handle_have(key, index)

  defp parse(@have_all_id, key), do: handle_have_all(key)

  defp parse(@have_none_id, key), do: handle_have_none(key)

  defp parse(<<@bitfield_id, bitfield::binary>>, key),
    do: handle_bitfield(key, bitfield)

  defp parse(<<@request_id, _::32, _::32, length::32>>, _)
       when length > @max_length,
       do: :protocol_error

  defp parse(<<@request_id, index::32, begin::32, length::32>>, key),
    do: handle_request(key, index, begin, length)

  defp parse(<<@piece_id, index::32, begin::32, block::binary>>, key),
    do: handle_piece(key, index, begin, block)

  defp parse(<<@cancel_id, index::32, begin::32, length::32>>, key),
    do: handle_cancel(key, index, begin, length)

  defp parse(<<@port_id, port::16>>, key),
    do: handle_port(key, port)

  defp parse(<<@suggest_piece_id, index::32>>, key),
    do: handle_suggest_piece(key, index)

  defp parse(<<@reject_request_id, index::32, begin::32, len::32>>, key),
    do: handle_reject(key, index, begin, len)

  defp parse(<<@allowed_fast_id, index::32>>, key),
    do: handle_allowed_fast(key, index)

  defp parse(_, _), do: :protocol_error
end

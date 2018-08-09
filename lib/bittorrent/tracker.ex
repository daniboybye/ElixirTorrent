defmodule Tracker do
  @type request_return :: [Peer.peer()]

  @spec first_request!(Path.t(), Peer.peer_id(), Acceptor.port_number()) ::
          {Torrent.Struct.t(), request_return()} | no_return()
  def first_request!(file_name, peer_id, port) do
    struct =
      file_name
      |> File.read!()
      |> Bencode.decode!()

    bytes = all_bytes_in_torrent(struct)

    last_index =
      struct["info"]["pieces"]
      |> byte_size()
      |> div(20)
      |> Kernel.-(1)

    torrent = %Torrent.Struct{
      hash: info_hash(struct),
      left: bytes,
      last_piece_length: bytes - last_index * struct["info"]["piece length"],
      struct: struct,
      last_index: last_index
    }

    {%Torrent.Struct{torrent | status: "empty"}, request!(torrent, peer_id, port)}
  end

  @spec request!(Torrent.Struct.t(), Peer.peer_id(), Acceptor.port_number()) ::
          request_return() | no_return()
  def request!(torrent, peer_id, port) do
    query =
      URI.encode_query(%{
        "info_hash" => torrent.hash,
        "peer_id" => peer_id,
        "port" => to_string(port),
        "compact" => "true",
        "uploaded" => torrent.uploaded,
        "downloaded" => torrent.downloaded,
        "left" => torrent.left,
        "event" => torrent.status
      })

    <<torrent.struct["announce"]::binary, "?", query::binary>>  
    |> HTTPoison.get!([], timeout: 25_000, recv_timeout: 25_000)
    |> Map.fetch!(:body)
    |> Bencode.decode!()
    |> Map.fetch!("peers")
  end

  defp info_hash(%{"info" => info}) do
    info
    |> Bencode.encode!()
    |> (&:crypto.hash(:sha, &1)).()
  end

  defp all_bytes_in_torrent(%{"info" => %{"length" => length}}), do: length

  defp all_bytes_in_torrent(%{"info" => %{"files" => list}}) do
    Enum.reduce(list, 0, fn %{"length" => x}, acc -> x + acc end)
  end
end

defmodule Tracker do
  @spec request!(Torrent.Struct.t(), Peer.peer_id(), Acceptor.port_number()) ::
        map() | no_return()
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
        "event" => torrent.status,
        "numwant" => if torrent.left == 0 do 0 else 125 end,
        "ip" => :inet.getif() 
          |> elem(1) 
          |> hd() 
          |> elem(0) 
          |> Tuple.to_list() 
          |> Enum.join(".")
      })

    <<torrent.struct["announce"]::binary, "?", query::binary>>  
    |> HTTPoison.get!([], timeout: 25_000, recv_timeout: 25_000)
    |> Map.fetch!(:body)
    |> Bencode.decode!()
  end
end

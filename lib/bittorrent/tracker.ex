defmodule Tracker do
  @spec request!(Torrent.Struct.t(), Peer.peer_id(), Acceptor.port_number()) ::
          map() | no_return()
  def request!(torrent, peer_id, port) do
    %{
      "info_hash" => torrent.hash,
      "peer_id" => peer_id,
      "port" => to_string(port),
      "compact" => 1,
      "uploaded" => torrent.uploaded,
      "downloaded" => torrent.downloaded,
      "left" => torrent.left,
      "event" => torrent.status,
      "numwant" =>
        if torrent.left == 0 do
          0
        else
          125
        end,
      "ip" => Acceptor.ip()
    }
    |> URI.encode_query()
    |> (&<<torrent.struct["announce"]::binary, "?", &1::binary>>).()
    |> HTTPoison.get!([], timeout: 25_000, recv_timeout: 25_000)
    |> Map.fetch!(:body)
    |> Bento.decode!()
  end
end

defmodule Torrent do
  use Supervisor, type: :supervisor, restart: :transient

  require Logger
  require Via

  Via.make()

  @type hash :: <<_::160>>
  @type index :: non_neg_integer()
  @type begin :: non_neg_integer()
  @type length :: pos_integer()
  @type block :: binary()
  @type bitfield :: binary()

  @spec start_link(Path.t(), Keyword.t()) :: Supervisor.on_start()
  def start_link(path, options) do
    torrent = parse_file!(path)
    Registry.put_meta(
      Registry, 
      torrent.hash, 
      check: Keyword.get(options, :check, false)
    ) 
    Supervisor.start_link(__MODULE__, torrent, name: via(torrent.hash))
  end

  defdelegate add_peer(hash, peer_id, socket), to: __MODULE__.Swarm

  defdelegate get(hash), to: __MODULE__.Server

  defdelegate torrent_downloaded?(hash), to: __MODULE__.Server

  defdelegate size(hash), to: __MODULE__.Server

  defdelegate new_peers(hash), to: __MODULE__.Server

  @spec get_hash(pid()) :: Torrent.hash()
  def get_hash(pid) do
    Registry
    |> Registry.keys(pid)
    |> hd()
    |> elem(0)
  end

  def restart(hash) do
    Registry.put_meta(
      Registry, 
      torrent.hash, 
      check: true
    )
    Supervisor.stop(via(hash), :error) 
  end

  def stop(hash) do
    Supervisor.stop(via(hash))
  end

  def init(torrent) do
    [
      {__MODULE__.Bitfield, torrent},
      {__MODULE__.PiecesStatistic, torrent},
      {__MODULE__.FileHandle, torrent},
      {__MODULE__.Uploader, torrent},
      {__MODULE__.Swarm, torrent},
      {__MODULE__.Downloads, torrent},
      {__MODULE__.Server, torrent}
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restarts: 0)
  end

  defp parse_file!(path) do
    struct =
      path
      |> File.read!()
      |> Bento.decode!()

    bytes = all_bytes_in_torrent(struct)

    last_index =
      struct["info"]["pieces"]
      |> byte_size()
      |> div(20)
      |> Kernel.-(1)

    %Torrent.Struct{
      hash: info_hash(struct),
      left: bytes,
      last_piece_length: bytes - last_index * struct["info"]["piece length"],
      struct: struct,
      last_index: last_index
    }
  end

  defp info_hash(%{"info" => info}) do
    info
    |> Bento.encode!()
    |> (&:crypto.hash(:sha, &1)).()
  end

  defp all_bytes_in_torrent(%{"info" => %{"length" => length}}), do: length

  defp all_bytes_in_torrent(%{"info" => %{"files" => list}}) do
    Enum.reduce(list, 0, fn %{"length" => x}, acc -> x + acc end)
  end
end

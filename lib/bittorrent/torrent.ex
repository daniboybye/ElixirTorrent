defmodule Torrent do
  use Supervisor, type: :supervisor, restart: :transient

  require Logger

  @type hash :: <<_::20>>
  @type index :: non_neg_integer()
  @type begin :: non_neg_integer()
  @type length :: pos_integer()
  @type block :: binary()
  @type bitfield :: binary()

  @spec start_link(Torrent.Struct.t()) :: Supervisor.on_start()
  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  defdelegate add_peer(hash, peer_id, socket), to: __MODULE__.Swarm

  defdelegate get(hash), to: __MODULE__.Server

  defdelegate torrent_downloaded?(hash), to: __MODULE__.Server

  defdelegate size(hash), to: __MODULE__.Server

  def init(torrent) do
    [
      {__MODULE__.FileHandle, torrent},
      {__MODULE__.Bitfield, torrent},
      {__MODULE__.PiecesStatistic, torrent},
      {__MODULE__.Uploader, torrent},
      {__MODULE__.Swarm, torrent},
      {__MODULE__.Downloads, torrent},
      {__MODULE__.Server, torrent}
    ]
    |> Supervisor.init(strategy: :one_for_all, max_restart: 0)
  end
end

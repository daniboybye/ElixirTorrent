defmodule Bittorrent.Torrent do 
  use Supervisor, type: :supervisor, restart: :transient

  import __MODULE__

  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  defdelegate add_peer(hash,peer_id,socket), to: Swarm

  defdelegate get(hash), to: Server

  defdelegate size(hash), to: FileHandle

  def init(%Struct{hash: hash,struct: %{"info" => info},
    pieces_count: pieces_count} = torrent) do
    [
      {FileHandle,      {hash, info}},
      {Bitfield,        {hash, pieces_count}},
      {Swarm.Statistic, {hash, pieces_count}},
      {Swarm,           hash},
      {Downloads,       hash},
      {Server,          torrent}
    ]
    |> Supervisor.init(strategy: :one_for_all)
  end
end
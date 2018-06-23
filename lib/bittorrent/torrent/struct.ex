defmodule Bittorent.Torrent.Struct do
  defstruct [info_hash: nil, struct: nil, 
  bytes: nil, uploaded: nil, downloaded: nil, status: nil,
  pieces_size: nil,
  bitfield: nil,
  pid: nil,
  peer_id: nil]

  def get_server(%__MODULE__{pid: pid}) do
    pid
    |> Supervisor.which_children()
    |> Enum.find(fn {x,_,_,_} -> x == Torrent.Server end)
    |> elem(1)
  end
end
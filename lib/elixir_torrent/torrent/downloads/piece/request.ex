defmodule Torrent.Downloads.Piece.Request do
  @moduledoc """
  In-flight subpiece request to a peer (begin/length + timeout timer).
  """

  @enforce_keys [:peer_id, :subpiece]
  defstruct [:peer_id, :subpiece, timer: nil]

  @type timer :: reference() | nil
  @type subpiece :: {Torrent.begin(), Torrent.length()}

  @type t :: %__MODULE__{
          peer_id: Peer.id(),
          subpiece: subpiece(),
          timer: timer()
        }
end

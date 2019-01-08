defmodule Peer.Controller.FastExtension do
  defstruct allowed_fast: AllowedFast.new(), allowed_fast_me: AllowedFast.new()

  @type t :: %__MODULE__{
          allowed_fast: AllowedFast.set(),
          allowed_fast_me: AllowedFast.set()
        }

  @type type :: t() | nil

  @spec make(Peer.reserved()) :: type()
  def make(x), do: if(Peer.fast_extension?(x), do: %__MODULE__{})

  @spec download?(type(), Torrent.index()) :: boolean()
  def download?(nil, _), do: false

  def download?(%__MODULE__{allowed_fast_me: set}, index) do
    MapSet.member?(set, index)
  end

  @spec upload?(type(), Torrent.index()) :: boolean()
  def upload?(nil, _), do: false

  def upload?(%__MODULE__{allowed_fast: set}, index) do
    MapSet.member?(set, index)
  end
end

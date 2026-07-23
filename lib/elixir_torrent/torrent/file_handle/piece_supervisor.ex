defmodule Torrent.FileHandle.PieceSupervisor do
  @moduledoc """
  Per-torrent `DynamicSupervisor` under which `Piece` processes are started on
  demand and reused while alive.

  `extra_arguments: [hash]` means a caller only passes `[index]` when starting a
  child; the hash is prepended so `Piece.start_link(hash, index)` is invoked.
  Piece children are `:temporary`, so an idle-terminated (or crashed) piece is
  simply forgotten — the next read/write/check lazily restarts it.
  """

  use Via

  @spec child_spec(Torrent.hash()) :: Supervisor.child_spec()
  def child_spec(hash) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {DynamicSupervisor, :start_link,
         [[name: via(hash), extra_arguments: [hash], strategy: :one_for_one, max_restarts: 100]]}
    }
  end

  @spec name(Torrent.hash()) :: GenServer.name()
  def name(hash), do: via(hash)
end

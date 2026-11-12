defmodule PieceReadShortFileTest do
  use ExUnit.Case, async: true

  alias Torrent.FileHandle.Piece

  test "reading past the end of a truncated file answers :error and keeps the piece alive" do
    dir = Path.join(System.tmp_dir!(), "piece_short_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "data.bin")
    File.write!(path, :binary.copy(<<1>>, 1024))

    # The layout claims 4 KiB but the file on disk holds only 1 KiB.
    piece = %Piece{hash: <<0::160>>, offset: 0, files: [{path, 4096}], length: 4096}
    {:ok, pid} = GenServer.start(Piece, piece)

    assert {:ok, <<1, _::binary>>} = GenServer.call(pid, {:read, 0, 512})
    assert :error = GenServer.call(pid, {:read, 2048, 512})
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end

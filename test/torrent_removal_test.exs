defmodule Torrent.RemovalTest do
  use ExUnit.Case, async: true

  alias Torrent.Removal

  defp sample_torrent(metadata_info) do
    %Torrent{
      hash: <<0::160>>,
      left: 0,
      last_index: 0,
      last_piece_length: 1,
      metadata: %{"info" => metadata_info}
    }
  end

  test "disk_paths for single-file torrent" do
    torrent = sample_torrent(%{"length" => 1_024, "name" => "ubuntu.iso"})

    assert Removal.disk_paths(torrent) == [Path.join(File.cwd!(), "ubuntu.iso")]
  end

  test "disk_paths for multi-file torrent" do
    torrent =
      sample_torrent(%{
        "files" => [
          %{"length" => 100, "path" => ["dir", "a.bin"]},
          %{"length" => 200, "path" => ["dir", "b.bin"]}
        ]
      })

    cwd = File.cwd!()

    assert Removal.disk_paths(torrent) == [
             Path.join([cwd, "dir", "a.bin"]),
             Path.join([cwd, "dir", "b.bin"])
           ]
  end

  test "delete_paths! removes files and empty parent directories" do
    root = Path.join(System.tmp_dir!(), "elixir_torrent_removal_#{System.unique_integer()}")
    dir = Path.join(root, "nested")
    file = Path.join(dir, "sample.bin")
    File.mkdir_p!(dir)
    File.write!(file, "data")

    on_exit(fn -> File.rm_rf(root) end)

    assert :ok = Removal.delete_paths!([file])
    refute File.exists?(file)
    refute File.exists?(dir)
    refute File.exists?(root)
  end
end

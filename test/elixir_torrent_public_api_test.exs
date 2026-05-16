defmodule ElixirTorrent.PublicApiTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    previous_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "et_public_api_#{System.unique_integer([:positive])}")
    download_dir = Path.join(tmp, "downloads")
    File.mkdir_p!(download_dir)
    File.cd!(tmp)

    on_exit(fn ->
      ElixirTorrent.stop_all_and_serialize()
      File.cd!(previous_cwd)
      File.rm_rf(tmp)
    end)

    %{download_dir: download_dir}
  end

  test "public API drives download, stats, persistence, resume, and removal", %{
    download_dir: download_dir
  } do
    {path, hash, name} = write_torrent!("public-api.bin", 42)

    assert {:ok, supervisor} =
             ElixirTorrent.download(path, download_dir: download_dir, resume: :skip)

    assert {:ok, ^supervisor} = Torrents.supervisor_pid(hash)
    assert {:ok, ^supervisor} = ElixirTorrent.download(path, download_dir: download_dir)
    assert hash in ElixirTorrent.list()

    assert {:ok, stats} = ElixirTorrent.stats(supervisor)
    assert stats.name == name
    assert stats.downloaded == 0
    assert stats.bytes_size == 42

    assert {:ok, %{left: 42, peer_status: nil}} =
             ElixirTorrent.stats(supervisor, [:left, :peer_status])

    assert [42, 0] = ElixirTorrent.get(supervisor, [:left, :downloaded])

    assert [
             %Torrent.Files.Entry{
               name: ^name,
               length: 42,
               downloaded: 0,
               complete?: false
             } = file
           ] = ElixirTorrent.list_files(hash)

    assert file.progress == 0.0

    assert :ok = ElixirTorrent.stop_and_serialize(hash)
    refute hash in ElixirTorrent.list()
    assert {:error, :not_found} = Torrents.supervisor_pid(hash)
    assert {:ok, session} = Torrent.Session.load(hash)
    assert session.left == 42

    assert {:ok, resumed} = ElixirTorrent.download(path, download_dir: download_dir)
    refute resumed == supervisor
    assert hash in ElixirTorrent.list()

    data_path = Path.join(download_dir, name)
    File.write!(data_path, :binary.copy(<<0>>, 42))
    assert File.regular?(data_path)

    assert :ok = ElixirTorrent.remove(hash, delete_data: true)
    refute hash in ElixirTorrent.list()
    refute File.exists?(data_path)
    assert :error = Torrent.Session.load(hash)

    assert :ok = ElixirTorrent.stop_and_serialize(hash)
  end

  test "stop_all_and_serialize persists every active torrent", %{download_dir: download_dir} do
    {path_a, hash_a, _} = write_torrent!("all-a.bin", 11)
    {path_b, hash_b, _} = write_torrent!("all-b.bin", 17)

    assert {:ok, _} = ElixirTorrent.download(path_a, download_dir: download_dir, resume: :skip)
    assert {:ok, _} = ElixirTorrent.download(path_b, download_dir: download_dir, resume: :skip)
    active = MapSet.new(ElixirTorrent.list())
    assert MapSet.subset?(MapSet.new([hash_a, hash_b]), active)

    assert :ok = ElixirTorrent.stop_all_and_serialize()
    refute hash_a in ElixirTorrent.list()
    refute hash_b in ElixirTorrent.list()
    assert {:ok, _} = Torrent.Session.load(hash_a)
    assert {:ok, _} = Torrent.Session.load(hash_b)
  end

  test "public API reports invalid pids and malformed magnets" do
    assert {:error, :torrent_not_found} = ElixirTorrent.stats(self())
    assert {:error, _reason} = ElixirTorrent.download_magnet("not-a-magnet")
  end

  defp write_torrent!(name, length) do
    info = %{
      "length" => length,
      "name" => name,
      "piece length" => 16_384,
      "pieces" => :crypto.hash(:sha, :binary.copy(<<0>>, length)),
      "private" => 1
    }

    info_blob = Bento.encode!(info)
    hash = :crypto.hash(:sha, info_blob)
    path = Path.join(File.cwd!(), "#{name}.torrent")
    File.write!(path, Bento.encode!(%{"info" => info}))
    {path, hash, name}
  end
end

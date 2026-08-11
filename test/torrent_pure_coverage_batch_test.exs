defmodule TorrentPureCoverageBatchTest do
  use ExUnit.Case, async: false

  alias Torrent.{
    Bitfield,
    Downloads,
    Files,
    Model,
    PathLayout,
    PiecesStatistic,
    Removal,
    Session,
    Superseed,
    WebSeed
  }

  @piece_len 512

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    prev = File.cwd!()

    tmp =
      System.tmp_dir!()
      |> Path.join("et_pure_cov_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(prev)
      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "Torrent.PiecesStatistic pure paths" do
    test "init from the owning process keeps the table registered" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2)

      assert :ok = PiecesStatistic.init(torrent)
      :ok = PiecesStatistic.set(hash, 0, :complete)
      assert PiecesStatistic.have?(hash, 0)
    end

    test "choice_piece returns nil when nothing is selectable" do
      hash = :crypto.strong_rand_bytes(20)

      with_stat_table(hash, 2, fn ->
        assert PiecesStatistic.choice_piece(hash, :random) == nil

        :ok = PiecesStatistic.inc(hash, 0)
        assert PiecesStatistic.choice_piece(hash, :rare, exclude: [0]) == nil
      end)
    end

    test "dec, dec_all, remove_peer, and reconcile_stale_statuses" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      bitfield =
        Bitfield.make(3)
        |> Bitfield.set(0, 1)
        |> Bitfield.set(2, 1)

      with_model(torrent, fn ->
        :ok = PiecesStatistic.update(hash, bitfield, 3)
        assert PiecesStatistic.availability(hash, 0) == 1
        assert PiecesStatistic.availability(hash, 2) == 1
        :ok = PiecesStatistic.remove_peer(hash, bitfield, 3)
        assert PiecesStatistic.availability(hash, 0) == 0
        assert PiecesStatistic.availability(hash, 2) == 0
        :ok = PiecesStatistic.update(hash, bitfield, 3)

        :ok = PiecesStatistic.dec(hash, 0)
        :ok = PiecesStatistic.dec_all(hash, 2)
        assert PiecesStatistic.availability(hash, 0) == 0
        assert PiecesStatistic.availability(hash, 2) == 0

        :ok = PiecesStatistic.set(hash, 1, :processing)
        assert 1 = PiecesStatistic.reconcile_stale_statuses(hash, fn _index -> false end)
        refute PiecesStatistic.have?(hash, 1)

        missing = :crypto.strong_rand_bytes(20)
        assert :ok = PiecesStatistic.remove_peer(missing, :all, 3)
        assert :ok = PiecesStatistic.remove_peer(missing, bitfield, 3)
        assert PiecesStatistic.get_status(missing, 0) == nil
      end)
    end
  end

  describe "Torrent.Files and PathLayout" do
    test "count/1 and variable piece_lengths progress math" do
      hash = :crypto.strong_rand_bytes(20)

      torrent =
        sample_torrent(hash, 3,
          piece_lengths: [100, 200, 50],
          last_piece_length: 50,
          bitfield: Bitfield.make(3) |> Bitfield.set(1, 1)
        )
        |> Map.put(:metadata, %{
          "info" => %{
            "name" => "parts",
            "piece length" => 100,
            "length" => 350,
            "pieces" => :crypto.strong_rand_bytes(60)
          }
        })

      {:ok, model} = Model.start_link(torrent)
      on_exit(fn -> safe_stop(model) end)

      assert Files.count(hash) == 1

      [entry] = Files.build_entries(torrent)
      assert entry.downloaded == 200
      assert entry.progress == entry.downloaded * 100.0 / entry.length
    end

    test "v2 merkle layout skips gaps and reports empty files at 100%" do
      piece_length = 16_384
      root = :crypto.hash(:sha256, "payload")

      merkle = %{
        piece_length: piece_length,
        files: [
          %{path: ["empty.bin"], length: 0, pieces_root: nil, piece_hashes: []},
          %{path: ["data.bin"], length: piece_length, pieces_root: root, piece_hashes: [root]}
        ]
      }

      torrent =
        sample_torrent(:crypto.strong_rand_bytes(20), 1,
          kind: :v2,
          merkle: merkle,
          last_piece_length: piece_length,
          metadata: %{
            "info" => %{
              "name" => "v2-root",
              "piece length" => piece_length,
              "meta version" => 2,
              "file tree" => %{"data.bin" => %{}}
            }
          }
        )

      entries = Files.build_entries(torrent)
      assert length(entries) == 2

      empty = Enum.find(entries, &(&1.name == "empty.bin"))
      data = Enum.find(entries, &(&1.name == "data.bin"))

      assert empty.progress == 100.0
      assert empty.complete?
      refute data.complete?
    end

    test "PathLayout v2 helpers sanitize traversal components" do
      info = %{
        "name" => "root",
        "file tree" => %{"a" => %{}},
        "meta version" => 2
      }

      assert PathLayout.v2_layout_path(info, ["..", "file"]) ==
               PathLayout.layout_path(info, ["..", "file"])

      assert PathLayout.layout_path(info, ["..", "file"]) == ["_", "file"]

      assert PathLayout.layout_path(%{"file tree" => "not-a-map", "name" => "root"}, ["a"]) == [
               "a"
             ]
    end
  end

  describe "Torrent.Bitfield and Downloads" do
    test "valid?/2 rejects malformed inputs" do
      refute Bitfield.valid?("too-short", 9)
      refute Bitfield.valid?(nil, 1)
      refute Bitfield.valid?(<<7>>, 3)
      refute Bitfield.valid?("x", 0)
    end

    test "stop, piece reuse, in-flight probe, and active_indices filtering" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2)

      assert :ok = Downloads.stop(hash)

      with_model(torrent, fn ->
        start_downloads(hash)
        parent = self()

        assert :ok =
                 Downloads.piece(hash, 0, fn -> send(parent, :downloaded) end, fn ->
                   send(parent, :dealt)
                 end)

        assert :ok =
                 Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)

        refute Downloads.piece_has_in_flight?(hash, 1)

        {:ok, decoy} = Agent.start_link(fn -> :ok end)
        DynamicSupervisor.start_child(downloads_via(hash), {Agent, fn -> :ok end})

        assert Downloads.active_indices(hash) == [0]

        safe_stop(decoy)
      end)
    end
  end

  describe "Torrent.Removal and Session persistence edges" do
    test "delete_data! and delete_paths! tolerate missing files" do
      hash = :crypto.strong_rand_bytes(20)
      root = Path.join(File.cwd!(), "delete-me")
      file = Path.join(root, "sample.bin")
      File.mkdir_p!(root)
      File.write!(file, "payload")

      torrent =
        sample_torrent(hash, 1,
          download_dir: root,
          metadata: %{"info" => %{"name" => "sample.bin", "length" => 7, "piece length" => 7}}
        )

      {:ok, model} = Model.start_link(torrent)
      on_exit(fn -> safe_stop(model) end)

      assert :ok = Removal.delete_data!(hash)
      refute File.exists?(file)
      assert :ok = Removal.delete_paths!([Path.join(root, "missing.bin")], root)
    end

    test "Session.load rescues corrupt payloads and delete surfaces non-enoent errors" do
      hash = :crypto.strong_rand_bytes(20)
      File.mkdir_p!(Session.dir())
      File.write!(Session.path(hash), "not-a-term")

      assert :error = Session.load(hash)

      File.write!(Session.path(hash), :erlang.term_to_binary(%{}))
      File.chmod!(Session.dir(), 0o500)

      on_exit(fn ->
        File.chmod!(Session.dir(), 0o700)
        File.rm(Session.path(hash))
      end)

      assert {:error, :eacces} = Session.delete(hash)
    end
  end

  describe "Torrent.Superseed callbacks" do
    test "assign, peer_have, confirm_seed, release, and suspended safe_call" do
      hash = :crypto.strong_rand_bytes(20)
      peer_a = <<11::160>>
      peer_b = <<22::160>>
      leech_bf = Bitfield.make(4)

      with_superseed(hash, fn ->
        assert :ok = Superseed.release(hash, peer_a)

        assert :ok = Superseed.peer_have(hash, peer_a, 0)
        assert :inactive = Superseed.confirm_seed(hash, peer_a)

        assert :armed = Superseed.arm(hash)
        assert :active = Superseed.activate(hash, 0)

        :ok = PiecesStatistic.inc(hash, 0)
        :ok = PiecesStatistic.inc(hash, 1)

        assert {:ok, first} = Superseed.assign(hash, peer_a, leech_bf)
        assert {:ok, ^first} = Superseed.assign(hash, peer_a, leech_bf)
        assert :ok = Superseed.peer_have(hash, peer_b, 99)

        assert {:rotate, ^peer_a, _} = Superseed.peer_have(hash, peer_a, first)

        peer_c = <<33::160>>
        assert :none = Superseed.assign(hash, peer_c, :all)
        assert :ok = Superseed.release(hash, peer_a)
      end)
    end

    test "pick_piece/4 prefers fresh rarest pieces" do
      availabilities = [{0, 3}, {1, 1}, {2, 1}]
      peer_has = MapSet.new([3])
      assigned = MapSet.new([4])
      advertised = MapSet.new([1])

      assert Superseed.pick_piece(availabilities, peer_has, assigned, advertised) == 2
    end
  end

  describe "Torrent.WebSeed decode and GenServer branches" do
    test "parse_url_list drops non-binary entries" do
      assert WebSeed.parse_url_list(%{"url-list" => [123, "http://ok/"]}) == ["http://ok/"]
    end

    test "init ignores missing Model and handle_info paths stay pure" do
      hash = :crypto.strong_rand_bytes(20)
      assert :ignore = WebSeed.start_link(hash)

      torrent =
        sample_torrent(hash, 1,
          metadata: %{
            "url-list" => "http://127.0.0.1:9/",
            "info" => %{"name" => "one.bin", "length" => @piece_len, "piece length" => @piece_len}
          }
        )

      {:ok, model} = Model.start_link(torrent)
      on_exit(fn -> safe_stop(model) end)

      assert {:ok, pid} = WebSeed.start_link(hash)
      on_exit(fn -> safe_stop(pid) end)

      send(pid, {:webseed_result, self(), 0, "http://127.0.0.1:9/", :ok})
      send(pid, :not_a_webseed_message)
      TestSupport.Sync.sync(pid)

      busy_pids =
        for _idx <- 0..1 do
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)
        end

      on_exit(fn -> Enum.each(busy_pids, &send(&1, :stop)) end)

      :sys.replace_state(pid, fn state ->
        busy_tasks =
          busy_pids
          |> Enum.with_index()
          |> Enum.map(fn {busy_pid, idx} ->
            {busy_pid, {make_ref(), idx, "http://busy/"}}
          end)

        %{state | tasks: Map.new(busy_tasks)}
      end)

      send(pid, :tick)
      TestSupport.Sync.sync(pid)
    end

    test "multi-file fetch builds BEP 19 directory URLs on loopback" do
      hash = :crypto.strong_rand_bytes(20)
      body = :binary.copy(<<0>>, @piece_len)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      parent = self()

      accept =
        spawn(fn ->
          {:ok, sock} = :gen_tcp.accept(listen)
          {:ok, req} = :gen_tcp.recv(sock, 0, 2_000)
          send(parent, {:http_request, req})
          send_http!(sock, 200, body)
          :gen_tcp.close(sock)
          :gen_tcp.close(listen)
        end)

      on_exit(fn ->
        Process.exit(accept, :kill)

        try do
          :gen_tcp.close(listen)
        catch
          :exit, _ -> :ok
        end
      end)

      torrent =
        sample_torrent(hash, 1,
          metadata: %{
            "url-list" => "http://127.0.0.1:#{port}/",
            "info" => %{
              "name" => "Album",
              "piece length" => @piece_len,
              "files" => [%{"length" => @piece_len, "path" => ["track1.mp3"]}]
            }
          }
        )

      {:ok, model} = Model.start_link(torrent)
      on_exit(fn -> safe_stop(model) end)

      assert {:ok, pid} = WebSeed.start_link(hash)
      on_exit(fn -> safe_stop(pid) end)

      send(pid, :tick)
      assert_receive {:http_request, request}, 2_000
      assert request =~ "Album/track1.mp3"
      TestSupport.Sync.sync(pid)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_torrent(hash, pieces_count, overrides \\ []) do
    struct!(
      %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "sample", "piece length" => @piece_len}},
        left: pieces_count * @piece_len,
        last_index: pieces_count - 1,
        last_piece_length: @piece_len,
        bitfield: Bitfield.make(pieces_count),
        peer_status: nil
      },
      overrides
    )
  end

  defp with_model(torrent, fun) do
    {:ok, model} = Model.start_link(torrent)
    on_exit(fn -> safe_stop(model) end)
    :ok = PiecesStatistic.init(torrent)
    fun.()
  end

  defp with_stat_table(hash, pieces_count, fun) do
    torrent = sample_torrent(hash, pieces_count)
    :ok = PiecesStatistic.init(torrent)
    fun.()
  end

  defp with_superseed(hash, fun) do
    torrent = sample_torrent(hash, 4)

    with_model(torrent, fn ->
      {:ok, pid} = Superseed.start_link(hash)
      on_exit(fn -> safe_stop(pid) end)
      fun.()
    end)
  end

  defp start_downloads(hash) do
    case DynamicSupervisor.start_link(
           name: downloads_via(hash),
           extra_arguments: [hash],
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp downloads_via(hash), do: {:via, Registry, {Registry, {hash, Downloads}}}

  defp send_http!(socket, code, body) do
    response =
      IO.iodata_to_binary([
        "HTTP/1.1 ",
        Integer.to_string(code),
        " OK\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\nConnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.send(socket, response)
  end

  defp safe_stop(pid) when is_pid(pid) do
    TestSupport.Sync.safe_stop(pid, 1_000)
  end
end

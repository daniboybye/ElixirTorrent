defmodule TorrentStorageCoverageBatchTest do
  use ExUnit.Case, async: false

  alias Torrent.{Bitfield, Downloads, Metadata, Model, Resume, Session, Swarm, Uploader, WebSeed}
  alias Torrent.Downloads.Piece
  alias Torrent.Downloads.Piece.{Request, State}

  @piece_len 256
  @peer_a <<11::160>>
  @peer_b <<22::160>>
  @stale_ms 20_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    prev = File.cwd!()

    tmp =
      System.tmp_dir!()
      |> Path.join("et_storage_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(prev)
      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "Torrent.Resume runtime" do
    test ":skip exits normally and notifies controller via resume_ready" do
      {torrent, _} = build_tiny_torrent([random_piece(), random_piece()])
      hash = torrent.hash

      with_storage_stack(torrent, fn _ ->
        with_controller(hash, fn controller ->
          {:ok, resume} = Resume.start_link({hash, :skip})
          ref = Process.monitor(resume)
          assert_receive {:DOWN, ^ref, :process, ^resume, :normal}, 2_000

          send(controller, :reconcile_pump)
          TestSupport.Sync.sync(controller)
          assert Process.alive?(controller)
          assert Model.get(hash, :left) == 2 * @piece_len
        end)
      end)
    end

    test ":verify_saved reconciles on-disk piece and progress counters" do
      piece0 = random_piece()
      piece1 = random_piece()

      bitfield =
        Bitfield.make(2)
        |> Bitfield.set(0, 1)

      {torrent, _} =
        build_tiny_torrent([piece0, piece1],
          bitfield: bitfield,
          downloaded: 0,
          left: 2 * @piece_len
        )

      hash = torrent.hash

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)

        with_controller(hash, fn _controller ->
          {:ok, resume} = Resume.start_link({hash, :verify_saved})
          ref = Process.monitor(resume)
          assert_receive {:DOWN, ^ref, :process, ^resume, :normal}, 5_000

          assert Torrent.have?(hash, 0)
          refute Torrent.have?(hash, 1)
          assert Model.get(hash, :downloaded) == @piece_len
          assert Model.get(hash, :left) == @piece_len
        end)
      end)
    end

    test ":verify_saved clears corrupt bitfield marks when disk bytes mismatch" do
      piece0 = random_piece()
      piece1 = random_piece()

      bitfield =
        Bitfield.make(2)
        |> Bitfield.set(0, 1)
        |> Bitfield.set(1, 1)

      {torrent, _} =
        build_tiny_torrent([piece0, piece1],
          bitfield: bitfield,
          downloaded: 2 * @piece_len,
          left: 0
        )

      hash = torrent.hash

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)
        # piece 1 left sparse — hash check must fail and clear bit 1

        with_controller(hash, fn _controller ->
          {:ok, resume} = Resume.start_link({hash, :verify_saved})
          ref = Process.monitor(resume)
          assert_receive {:DOWN, ^ref, :process, ^resume, :normal}, 5_000

          assert Torrent.have?(hash, 0)
          refute Torrent.have?(hash, 1)
          assert Model.get(hash, :downloaded) == @piece_len
          assert Model.get(hash, :left) == @piece_len
        end)
      end)
    end

    test ":full_scan treats sparse zeros as absent without treating them as corrupt" do
      piece0 = random_piece()
      piece1 = random_piece()

      {torrent, _} =
        build_tiny_torrent([piece0, piece1],
          bitfield: Bitfield.make(2),
          downloaded: 0,
          left: 2 * @piece_len
        )

      hash = torrent.hash

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 1, piece1)

        with_controller(hash, fn _controller ->
          {:ok, resume} = Resume.start_link({hash, :full_scan})
          ref = Process.monitor(resume)
          assert_receive {:DOWN, ^ref, :process, ^resume, :normal}, 5_000

          refute Torrent.have?(hash, 0)
          assert Torrent.have?(hash, 1)
          assert Model.get(hash, :downloaded) == @piece_len
          assert Model.get(hash, :left) == @piece_len
        end)
      end)
    end

    test "completed resume promotes to seed without repeating completed and persists session" do
      piece0 = random_piece()
      piece1 = random_piece()

      bitfield =
        Bitfield.make(2)
        |> Bitfield.set(0, 1)
        |> Bitfield.set(1, 1)

      {torrent, _} =
        build_tiny_torrent([piece0, piece1],
          bitfield: bitfield,
          downloaded: 2 * @piece_len,
          left: 0
        )

      torrent = %{torrent | event: Torrent.empty()}
      hash = torrent.hash
      Session.delete(hash)

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)
        write_piece!(hash, 1, piece1)

        with_controller(hash, fn _controller ->
          {:ok, resume} = Resume.start_link({hash, :verify_saved})
          ref = Process.monitor(resume)
          assert_receive {:DOWN, ^ref, :process, ^resume, :normal}, 5_000

          assert Model.downloaded?(hash)
          assert Model.get(hash, :peer_status) == :seed
          assert Model.get(hash, :event) == Torrent.empty()
          assert {:ok, session} = Session.load(hash)
          assert session.left == 0
          assert Bitfield.have?(session.bitfield, 0)
          assert Bitfield.have?(session.bitfield, 1)
        end)
      end)
    end
  end

  describe "Torrent.Uploader with FileHandle" do
    @tag race_group: :uploader
    test "request reads bytes via FileHandle and accounts upload volume" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])
      hash = torrent.hash
      parent = self()

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)
        start_uploader_supervisor(hash)

        assert {:ok, task_pid} =
                 Uploader.request(hash, @peer_a, 0, 0, 128, fn block ->
                   send(parent, {:block, block})
                 end)

        assert_receive {:block, block}, 2_000
        assert byte_size(block) == 128
        assert block == binary_part(piece0, 0, 128)

        await_uploader_task(task_pid)
        sync_model(hash)
        assert Model.get(hash, :uploaded) == 128
      end)
    end

    @tag race_group: :uploader
    test "cancelled callback does not account bytes that were never sent" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])
      hash = torrent.hash
      parent = self()

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)
        start_uploader_supervisor(hash)

        assert {:ok, _task} =
                 Uploader.request(hash, @peer_a, 0, 0, 128, fn _block ->
                   send(parent, :callback_cancelled)
                   :cancelled
                 end)

        assert_receive :callback_cancelled, 2_000
        assert Model.get(hash, :uploaded) == 0
      end)
    end

    @tag race_group: :uploader
    test "peer teardown during completion quietly cancels the upload" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])
      hash = torrent.hash
      {controller, controller_ref} = spawn_monitor(fn -> :ok end)
      parent = self()
      release = make_ref()

      assert_receive {:DOWN, ^controller_ref, :process, ^controller, :normal}, 1_000

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)
        start_uploader_supervisor(hash)

        assert {:ok, task_pid} =
                 Uploader.request(hash, @peer_a, 0, 0, 128, fn block ->
                   send(parent, {:upload_callback_ready, self()})
                   receive do: (^release -> :ok)
                   GenServer.call(controller, {:complete_upload, 0, 0, 128, block})
                 end)

        assert_receive {:upload_callback_ready, ^task_pid}, 2_000
        task_ref = Process.monitor(task_pid)
        send(task_pid, release)
        assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}, 2_000
        assert Model.get(hash, :uploaded) == 0
      end)
    end

    @tag race_group: :uploader
    test "unexpected callback exits remain visible" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])
      hash = torrent.hash
      parent = self()
      release = make_ref()

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)
        start_uploader_supervisor(hash)

        assert {:ok, task_pid} =
                 Uploader.request(hash, @peer_a, 0, 0, 64, fn _block ->
                   send(parent, {:failing_callback_ready, self()})
                   receive do: (^release -> :ok)
                   exit(:upload_callback_failure)
                 end)

        assert_receive {:failing_callback_ready, ^task_pid}, 2_000
        task_ref = Process.monitor(task_pid)
        send(task_pid, release)

        assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :upload_callback_failure}, 2_000
        assert Model.get(hash, :uploaded) == 0
      end)
    end

    @tag race_group: :uploader
    test "cancel terminates an in-flight upload task registered in Registry" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])
      hash = torrent.hash
      parent = self()
      release = make_ref()

      with_storage_stack(torrent, fn _ ->
        write_piece!(hash, 0, piece0)
        start_uploader_supervisor(hash)

        assert {:ok, task_pid} =
                 Uploader.request(hash, @peer_a, 0, 0, 64, fn _block ->
                   send(parent, :in_callback)
                   receive do: (^release -> :ok)
                 end)

        assert_receive :in_callback, 2_000
        assert :ok = Uploader.cancel(hash, @peer_a, 0, 0, 64)

        ref = Process.monitor(task_pid)
        assert_receive {:DOWN, ^ref, :process, ^task_pid, _}, 2_000

        name = {0, 64, 0, @peer_a, hash}
        TestSupport.Sync.sync(Registry.PIDPartition0)
        assert Registry.lookup(Registry, name) == []
      end)
    end
  end

  describe "Torrent.Metadata" do
    test "serve?/1 and metadata_size/1 reflect completion and info_blob presence" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])

      with_model(torrent, fn hash ->
        model_pid = GenServer.whereis({:via, Registry, {Registry, {hash, Model}}})

        refute Metadata.serve?(hash)
        assert Metadata.info_blob(hash) == torrent.info_blob
        assert Metadata.metadata_size(hash) == byte_size(torrent.info_blob)

        completed =
          torrent
          |> Map.put(:left, 0)
          |> Map.put(:downloaded, @piece_len)
          |> Map.put(:bitfield, Bitfield.make(1) |> Bitfield.set(0, 1))

        safe_stop(model_pid)
        {:ok, _} = Model.start_link(completed)

        assert Metadata.serve?(hash)
        assert Metadata.metadata_size(hash) == byte_size(torrent.info_blob)
      end)
    end

    test "serve?/1 is false without info_blob even when left is zero" do
      hash = :crypto.strong_rand_bytes(20)

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "x", "piece length" => @piece_len}},
        left: 0,
        downloaded: @piece_len,
        last_index: 0,
        last_piece_length: @piece_len,
        bitfield: Bitfield.make(1) |> Bitfield.set(0, 1),
        info_blob: nil
      }

      with_model(torrent, fn h ->
        refute Metadata.serve?(h)
        assert Metadata.info_blob(h) == nil
        assert Metadata.metadata_size(h) == nil
      end)
    end
  end

  describe "Torrent.WebSeed GenServer branches" do
    test "init returns :ignore when metadata has no url-list" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])

      with_model(torrent, fn hash ->
        assert :ignore = WebSeed.start_link(hash)
      end)
    end

    test "init starts when url-list is present and :tick schedules fetches" do
      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0], url_list: ["http://127.0.0.1:1/"])

      with_webseed_stack(torrent, fn hash, pid ->
        assert Process.alive?(pid)
        send(pid, :tick)
        TestSupport.Sync.sync(pid)
        assert Process.alive?(pid)
        refute Model.downloaded?(hash)
      end)
    end

    test "handle_info clears tasks on webseed_result ok and error" do
      piece0 = random_piece()
      url = "http://127.0.0.1:9/missing"
      {torrent, _} = build_tiny_torrent([piece0], url_list: [url])

      with_webseed_stack(torrent, fn _hash, pid ->
        fake = spawn(fn -> :ok end)
        ref = Process.monitor(fake)
        state = :sys.get_state(pid)
        tasks = Map.put(state.tasks, fake, {ref, 0, url})

        :sys.replace_state(pid, fn s -> %{s | tasks: tasks} end)

        send(pid, {:webseed_result, fake, 0, url, :ok})
        TestSupport.Sync.sync(pid)

        refute Map.has_key?(:sys.get_state(pid).tasks, fake)

        fake2 = spawn(fn -> :ok end)
        ref2 = Process.monitor(fake2)

        :sys.replace_state(pid, fn s ->
          %{s | tasks: Map.put(%{}, fake2, {ref2, 0, url})}
        end)

        send(pid, {:webseed_result, fake2, 0, url, {:error, :timeout}})
        TestSupport.Sync.sync(pid)

        penalised = :sys.get_state(pid).url_state
        assert Map.has_key?(penalised, url)
        assert :sys.get_state(pid).tasks == %{}
      end)
    end

    test "handle_info {:DOWN, ...} penalises URL and clears task slot" do
      piece0 = random_piece()
      url = "http://127.0.0.1:9/down"
      {torrent, _} = build_tiny_torrent([piece0], url_list: [url])

      with_webseed_stack(torrent, fn _hash, pid ->
        task = spawn(fn -> :ok end)
        ref = make_ref()
        :sys.replace_state(pid, fn s -> %{s | tasks: %{task => {ref, 0, url}}} end)

        send(pid, {:DOWN, ref, :process, task, :killed})
        TestSupport.Sync.sync(pid)

        state = :sys.get_state(pid)
        assert state.tasks == %{}
        assert Map.has_key?(state.url_state, url)
      end)
    end

    test "loopback HTTP range fetch completes a missing piece" do
      piece0 = random_piece()
      port = start_range_http_server(piece0)
      url = "http://127.0.0.1:#{port}/tiny.bin"

      {torrent, _} = build_tiny_torrent([piece0], url_list: [url])

      with_webseed_stack(torrent, fn hash, pid ->
        send(pid, :tick)
        await_webseed_tasks(pid)
        assert Torrent.have?(hash, 0)
        assert Model.get(hash, :downloaded) == @piece_len
        assert Model.get(hash, :left) == 0
      end)
    end

    test "schedules two different pieces concurrently without crashing" do
      piece0 = random_piece()
      piece1 = random_piece()
      {port, server_ref} = start_controlled_http_server()
      url = "http://127.0.0.1:#{port}/tiny.bin"
      {torrent, _} = build_tiny_torrent([piece0, piece1], url_list: [url])

      with_webseed_stack(torrent, fn hash, pid ->
        monitor = Process.monitor(pid)
        send(pid, :tick)

        assert_receive {:webseed_http_request, ^server_ref, first, first_request}, 2_000

        send(pid, :tick)

        assert_receive {:webseed_http_request, ^server_ref, second, second_request}, 2_000
        refute first == second

        indices =
          pid
          |> :sys.get_state()
          |> Map.fetch!(:tasks)
          |> Map.values()
          |> Enum.map(fn {_ref, index, _url} -> index end)
          |> Enum.sort()

        assert indices == [0, 1]
        refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 0

        reply_for_range(first, first_request, piece0, piece1)
        reply_for_range(second, second_request, piece0, piece1)

        await_webseed_tasks(pid)
        assert Model.downloaded?(hash)
        assert Process.alive?(pid)
      end)
    end

    test "hash-mismatching mirror is disabled for the rest of the session" do
      piece0 = random_piece()
      {port, server_ref} = start_controlled_http_server()
      url = "http://127.0.0.1:#{port}/tiny.bin"
      {torrent, _} = build_tiny_torrent([piece0], url_list: [url])

      with_webseed_stack(torrent, fn hash, pid ->
        send(pid, :tick)
        assert_receive {:webseed_http_request, ^server_ref, request_pid, _request}, 2_000
        reply_http(request_pid, 206, corrupt_piece(piece0))

        await_webseed_tasks(pid)

        state = :sys.get_state(pid)
        assert state.tasks == %{}
        assert MapSet.member?(state.disabled_urls, url)
        refute Map.has_key?(state.url_state, url)

        send(pid, :tick)
        send(pid, :tick)
        refute_receive {:webseed_http_request, ^server_ref, _request_pid, _request}, 200
        refute Torrent.have?(hash, 0)
        assert Process.alive?(pid)
      end)
    end

    test "transient HTTP failure backs off and retries after the deadline" do
      piece0 = random_piece()
      {port, server_ref} = start_controlled_http_server()
      url = "http://127.0.0.1:#{port}/tiny.bin"
      {torrent, _} = build_tiny_torrent([piece0], url_list: [url])

      with_webseed_stack(torrent, fn hash, pid ->
        send(pid, :tick)
        assert_receive {:webseed_http_request, ^server_ref, first, _request}, 2_000
        reply_http(first, 503, "temporarily unavailable")

        await_webseed_tasks(pid)

        state = :sys.get_state(pid)
        assert state.tasks == %{}
        assert Map.has_key?(state.url_state, url)
        refute MapSet.member?(state.disabled_urls, url)

        send(pid, :tick)
        refute_receive {:webseed_http_request, ^server_ref, _request_pid, _request}, 200

        :sys.replace_state(pid, fn state ->
          update_in(state.url_state[url].next_ok_at_ms, fn _ ->
            System.monotonic_time(:millisecond) - 1
          end)
        end)

        send(pid, :tick)
        assert_receive {:webseed_http_request, ^server_ref, second, _request}, 2_000
        reply_http(second, 206, piece0)

        await_webseed_tasks(pid)
        assert Torrent.have?(hash, 0)
        assert Process.alive?(pid)
      end)
    end
  end

  describe "Torrent.Swarm assignment and pin branches" do
    test "assign_peer_to_piece?/3 is false when peer lacks the piece bit" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)

      with_model(torrent, fn _ ->
        start_swarm(hash)
        {_pid, key} = add_swarm_peer(hash, @peer_a, index: nil, bitfield: Bitfield.make(4))

        refute Swarm.assign_peer_to_piece?(hash, key, 0)
      end)
    end

    test "assign_peer_to_piece?/3 accepts nil pin and keeps same-index pin" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)
      bf = both_pieces()

      with_model(torrent, fn _ ->
        start_swarm(hash)
        {_pid, key_a} = add_swarm_peer(hash, @peer_a, index: nil, bitfield: bf)
        {_pid, key_b} = add_swarm_peer(hash, @peer_b, index: 1, bitfield: bf)

        assert Swarm.assign_peer_to_piece?(hash, key_a, 0)
        assert Swarm.assign_peer_to_piece?(hash, key_b, 1)
      end)
    end

    test "assign_peer_to_piece?/3 frees pin when prior piece is no longer active" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)
      bf = both_pieces()

      with_model(torrent, fn _ ->
        start_swarm(hash)
        {_pid, key} = add_swarm_peer(hash, @peer_a, index: 0, bitfield: bf)

        assert Swarm.assign_peer_to_piece?(hash, key, 1, [1])
      end)
    end

    test "assign_peer_to_piece?/3 frees drained non-endgame pin to another active piece" do
      hash = :crypto.strong_rand_bytes(20)

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "drained-pin", "piece length" => 16_384}},
        left: 2 * 16_384,
        last_index: 1,
        last_piece_length: 16_384,
        peer_status: nil
      }

      bf =
        Bitfield.make(2)
        |> Bitfield.set(0, 1)
        |> Bitfield.set(1, 1)

      with_model(torrent, fn _ ->
        start_swarm(hash)
        start_downloads(hash)
        Downloads.piece(hash, 1, fn -> :ok end, fn -> :ok end)
        piece_pid = Piece.whereis(hash, 1)
        assert is_pid(piece_pid)
        TestSupport.Sync.sync(piece_pid)
        assert 1 in Downloads.active_indices(hash)

        {_pid, key} =
          add_swarm_peer(hash, @peer_b,
            index: 0,
            bitfield: bf,
            choke_me: false,
            stale: false
          )

        assert Swarm.assign_peer_to_piece?(hash, key, 1)
      end)
    end

    test "sort_peers_seeders_first ranks seeders ahead of leechers" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = endgame_torrent(hash)

      seeder_bf =
        Bitfield.make(4)
        |> Bitfield.set(0, 1)
        |> Bitfield.set(1, 1)

      leech_bf = Bitfield.make(4) |> Bitfield.set(0, 1)

      with_model(torrent, fn _ ->
        start_swarm(hash)

        {seeder_pid, seeder_key} =
          add_swarm_peer(hash, @peer_a, index: nil, bitfield: seeder_bf)

        {leech_pid, _} = add_swarm_peer(hash, @peer_b, index: nil, bitfield: leech_bf)

        :sys.replace_state({:via, Registry, {Registry, {seeder_key, Peer.Controller}}}, fn s ->
          %{s | bitfield: :all}
        end)

        assert [^seeder_pid, ^leech_pid] = Swarm.sort_peers_seeders_first([leech_pid, seeder_pid])
      end)
    end
  end

  describe "Torrent.Controller handle_info lifecycle" do
    test ":resume_ready accepts reconcile and next_piece without crashing" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 3)

      with_model(torrent, fn _ ->
        with_controller(hash, fn pid ->
          send(pid, :resume_ready)
          TestSupport.Sync.sync(pid)
          send(pid, :reconcile_pump)
          send(pid, {:next_piece, :random})
          TestSupport.Sync.sync(pid)
          assert Process.alive?(pid)
        end)
      end)
    end

    test "{:next_piece, _} on completed torrent marks seed and stops downloads" do
      hash = :crypto.strong_rand_bytes(20)

      torrent = %Torrent{
        hash: hash,
        metadata: %{"info" => %{"name" => "done", "piece length" => 16_384}},
        left: 0,
        downloaded: 2 * 16_384,
        last_index: 1,
        last_piece_length: 16_384,
        bitfield:
          Bitfield.make(2)
          |> Bitfield.set(0, 1)
          |> Bitfield.set(1, 1),
        peer_status: nil
      }

      with_model(torrent, fn _ ->
        start_swarm(hash)
        start_downloads(hash)
        Downloads.piece(hash, 0, fn -> :ok end, fn -> :ok end)
        piece0_pid = Piece.whereis(hash, 0)
        assert is_pid(piece0_pid)
        TestSupport.Sync.sync(piece0_pid)
        assert Downloads.piece_active?(hash, 0)

        with_controller(hash, fn pid ->
          send(pid, {:next_piece, :random})
          TestSupport.Sync.sync(pid)

          assert Model.get(hash, :peer_status) == :seed
          refute Downloads.piece_active?(hash, 0)
        end)
      end)
    end

    test ":unchoke and :reset_rank cycle without crashing when swarm is empty" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2)

      with_model(torrent, fn _ ->
        start_swarm(hash)

        with_controller(hash, fn pid ->
          send(pid, :unchoke)
          send(pid, :reset_rank)
          TestSupport.Sync.sync(pid)
          assert Process.alive?(pid)
        end)
      end)
    end

    test ":reconcile_pump kicks next_piece when peers exist and capacity remains" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 4)

      with_model(torrent, fn _ ->
        start_swarm(hash)
        start_downloads(hash)
        :ok = Torrent.PiecesStatistic.inc_all(hash, torrent.last_index)

        add_swarm_peer(hash, @peer_a,
          index: nil,
          bitfield: Bitfield.make(4) |> Bitfield.set(0, 1),
          choke_me: false,
          stale: false
        )

        with_controller(hash, fn pid ->
          reached? =
            Enum.reduce_while(1..12, false, fn _, _ ->
              send(pid, :reconcile_pump)
              TestSupport.Sync.sync(pid)

              if Downloads.active_indices(hash) != [] do
                {:halt, true}
              else
                {:cont, false}
              end
            end)

          assert reached?
        end)
      end)
    end
  end

  describe "Torrent.Downloads.Piece.State critical branches" do
    test "download/3 with empty waiting and requests invokes requests_are_dealt" do
      hash = :crypto.strong_rand_bytes(20)
      parent = self()

      state =
        %State{
          hash: hash,
          index: 0,
          waiting: [],
          requests: [],
          requests_are_dealt: fn -> send(parent, :dealt) end
        }
        |> State.download(fn -> :ok end, fn -> :ok end)

      assert_receive :dealt, 100
      assert state.waiting == []
    end

    test "download/3 re-queues in-flight requests when waiting is empty" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 1, @piece_len)
      subpiece = {0, @piece_len}

      with_model(torrent, fn _ ->
        state = %State{
          hash: hash,
          index: 0,
          waiting: [],
          requests: [%Request{peer_id: @peer_a, subpiece: subpiece, timer: nil}]
        }

        new_state =
          State.download(state, fn -> :ok end, fn -> :ok end)

        assert subpiece in new_state.waiting
        assert new_state.requests == []
      end)
    end

    test "response/4 ignores out-of-range subpieces" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 1, @piece_len)

      with_model(torrent, fn _ ->
        state =
          State.make({hash, 0})
          |> Map.put(:waiting, [{0, @piece_len}])

        unchanged = State.response(state, @peer_a, @piece_len, <<0::256>>)
        assert unchanged.waiting == state.waiting
      end)
    end

    test "reject/4 re-queues subpieces in normal mode" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 1, @piece_len)
      subpiece = {0, @piece_len}

      with_model(torrent, fn _ ->
        state = %State{
          hash: hash,
          index: 0,
          mode: nil,
          waiting: [],
          requests: [%Request{peer_id: @peer_a, subpiece: subpiece, timer: nil}]
        }

        new_state = State.reject(state, @peer_a, 0, @piece_len)
        assert subpiece in new_state.waiting
        assert new_state.requests == []
      end)
    end

    test "timeout/2 re-queues waiting blocks in normal mode" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 1, @piece_len)
      subpiece = {0, @piece_len}

      with_model(torrent, fn _ ->
        state = %State{
          hash: hash,
          index: 0,
          mode: nil,
          waiting: [],
          requests: [%Request{peer_id: @peer_a, subpiece: subpiece, timer: nil}]
        }

        new_state = State.timeout(state, @peer_a)
        assert subpiece in new_state.waiting
      end)
    end

    test "orphan_no_sources?/1 is true with empty monitoring and no swarm peers" do
      hash = :crypto.strong_rand_bytes(20)
      torrent = sample_torrent(hash, 2)

      with_model(torrent, fn _ ->
        state = %State{hash: hash, index: 0, waiting: [{0, 16_384}], monitoring: %{}}
        assert State.orphan_no_sources?(state)
      end)
    end

    test "release_in_flight_requests/1 cancels tracked requests" do
      hash = :crypto.strong_rand_bytes(20)
      subpiece = {0, 16_384}

      state = %State{
        hash: hash,
        index: 0,
        waiting: [],
        requests: [%Request{peer_id: @peer_a, subpiece: subpiece, timer: nil}]
      }

      assert :ok = State.release_in_flight_requests(state)
    end

    test "subpieces/2 returns MapSet of peer-owned in-flight subpieces" do
      hash = :crypto.strong_rand_bytes(20)
      a = {0, 16_384}
      b = {16_384, 16_384}

      state = %State{
        hash: hash,
        index: 0,
        waiting: [],
        requests: [
          %Request{peer_id: @peer_a, subpiece: a, timer: nil},
          %Request{peer_id: @peer_b, subpiece: b, timer: nil},
          %Request{peer_id: @peer_a, subpiece: b, timer: nil}
        ]
      }

      assert MapSet.new([a, b]) == State.subpieces(state, @peer_a)
      assert MapSet.new([b]) == State.subpieces(state, @peer_b)
    end
  end

  describe "Torrents API smoke" do
    test "list/0 returns only registered torrent supervisor hashes" do
      assert is_list(Torrents.list())

      piece0 = random_piece()
      {torrent, _} = build_tiny_torrent([piece0])
      path = write_torrent_file!(torrent)

      assert {:ok, pid} = Torrents.download(path, resume: :skip)
      on_exit(fn -> safe_stop(pid) end)

      assert torrent.hash in Torrents.list()
      assert {:ok, stats} = Torrents.stats(pid, [:name, :downloaded])
      assert stats.name == "tiny.bin"
    end

    test "stats/1 returns not_found for unknown pid" do
      assert {:error, :torrent_not_found} = Torrents.stats(self())
    end
  end

  ## helpers -----------------------------------------------------------------

  defp random_piece, do: :crypto.strong_rand_bytes(@piece_len)

  defp build_tiny_torrent(piece_bins, opts \\ []) do
    piece_bins = normalize_piece_bins(piece_bins)
    {info_map, info_blob, hash} = build_tiny_info(piece_bins, opts)
    torrent = build_tiny_torrent_struct(info_map, info_blob, hash, piece_bins, opts)
    {torrent, piece_bins}
  end

  defp normalize_piece_bins(piece_bins) do
    Enum.map(piece_bins, fn bin ->
      if byte_size(bin) == @piece_len, do: bin, else: pad_piece(bin)
    end)
  end

  defp build_tiny_info(piece_bins, opts) do
    pieces_hash =
      piece_bins
      |> Enum.map(fn bin -> :crypto.hash(:sha, bin) end)
      |> IO.iodata_to_binary()

    total_len = length(piece_bins) * @piece_len

    info_map = %{
      "name" => "tiny.bin",
      "length" => total_len,
      "piece length" => @piece_len,
      "pieces" => pieces_hash
    }

    info_blob = Bento.encode!(info_map)
    hash = Keyword.get(opts, :hash, :crypto.hash(:sha, info_blob))
    {info_map, info_blob, hash}
  end

  defp build_tiny_torrent_struct(info_map, info_blob, hash, piece_bins, opts) do
    total_len = length(piece_bins) * @piece_len

    metadata =
      %{"info" => info_map}
      |> maybe_put_url_list(Keyword.get(opts, :url_list))

    bitfield = Keyword.get(opts, :bitfield, Bitfield.make(length(piece_bins)))

    %Torrent{
      hash: hash,
      metadata: metadata,
      info_blob: info_blob,
      left: Keyword.get(opts, :left, total_len),
      downloaded: Keyword.get(opts, :downloaded, 0),
      last_index: length(piece_bins) - 1,
      last_piece_length: @piece_len,
      bitfield: bitfield,
      download_dir: File.cwd!(),
      peer_status: nil
    }
  end

  defp maybe_put_url_list(meta, nil), do: meta
  defp maybe_put_url_list(meta, urls), do: Map.put(meta, "url-list", urls)

  defp pad_piece(bin) do
    pad = @piece_len - byte_size(bin)
    bin <> :binary.copy(<<0>>, pad)
  end

  defp write_torrent_file!(%Torrent{} = torrent) do
    info_blob = torrent.info_blob

    bytes =
      IO.iodata_to_binary([
        "d",
        bstr("info"),
        info_blob,
        "e"
      ])

    path = Path.join(File.cwd!(), "tiny.torrent")
    File.write!(path, bytes)
    path
  end

  defp bstr(binary), do: [Integer.to_string(byte_size(binary)), ":", binary]

  defp with_model(torrent, fun) do
    {:ok, model_pid} = Model.start_link(torrent)

    on_exit(fn -> safe_stop(model_pid) end)

    :ok = Torrent.PiecesStatistic.init(torrent)
    fun.(torrent.hash)
  end

  defp with_controller(hash, fun) do
    {:ok, pid} = Torrent.Controller.start_link(hash)
    Process.unlink(pid)

    try do
      fun.(pid)
    after
      safe_stop(pid)
    end
  end

  defp with_storage_stack(torrent, fun) do
    with_model(torrent, fn hash ->
      {:ok, fh_pid} = Torrent.FileHandle.start_link(hash)
      on_exit(fn -> safe_stop(fh_pid) end)
      fun.(hash)
    end)
  end

  defp with_webseed_stack(torrent, fun) do
    with_storage_stack(torrent, fn hash ->
      start_downloads(hash)
      start_swarm(hash)

      case WebSeed.start_link(hash) do
        :ignore -> flunk("expected WebSeed to start for url-list torrent")
        {:ok, pid} -> fun.(hash, pid)
      end
    end)
  end

  defp write_piece!(hash, index, data) do
    :ok = Torrent.FileHandle.write(hash, index, 0, data)
    :ok = Torrent.FileHandle.flush(hash, index)
  end

  defp start_uploader_supervisor(hash) do
    case Task.Supervisor.start_link(name: uploader_via(hash), max_restarts: 0) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp uploader_via(hash), do: {:via, Registry, {Registry, {hash, Uploader}}}

  defp start_range_http_server(body) when is_binary(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        serve_range_http(listen, body)
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp start_controlled_http_server do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    owner = self()
    server_ref = make_ref()

    server =
      spawn(fn ->
        serve_controlled_http(listen, owner, server_ref)
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end)

    {port, server_ref}
  end

  defp serve_controlled_http(listen, owner, server_ref) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> handle_controlled_http_connection(socket, owner, server_ref) end)

        serve_controlled_http(listen, owner, server_ref)

      {:error, _} ->
        :ok
    end
  end

  defp handle_controlled_http_connection(socket, owner, server_ref) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, request} ->
        send(owner, {:webseed_http_request, server_ref, self(), request})

        receive do
          {:webseed_http_reply, code, body} ->
            send_http_response(socket, code, body)
        after
          5_000 -> :ok
        end

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp reply_for_range(request_pid, request, piece0, piece1) do
    cond do
      String.contains?(request, "Range: bytes=0-255") ->
        reply_http(request_pid, 206, piece0)

      String.contains?(request, "Range: bytes=256-511") ->
        reply_http(request_pid, 206, piece1)

      true ->
        flunk("unexpected webseed range request: #{inspect(request)}")
    end
  end

  defp reply_http(request_pid, code, body) do
    send(request_pid, {:webseed_http_reply, code, body})
  end

  defp corrupt_piece(<<first, rest::binary>>) do
    <<Bitwise.bxor(first, 1), rest::binary>>
  end

  defp send_http_response(socket, code, body) do
    status =
      case code do
        200 -> "200 OK"
        206 -> "206 Partial Content"
        503 -> "503 Service Unavailable"
      end

    response =
      IO.iodata_to_binary([
        "HTTP/1.1 ",
        status,
        "\r\nContent-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\nConnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.send(socket, response)
  end

  defp serve_range_http(listen, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> handle_range_http_connection(socket, body) end)

        serve_range_http(listen, body)

      {:error, _} ->
        :ok
    end
  end

  defp handle_range_http_connection(socket, body) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, request} ->
        {code, resp_body, extra} = range_response(request, body)
        send_http_range_response(socket, code, resp_body, extra)

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp send_http_range_response(socket, code, resp_body, extra) do
    status =
      case code do
        200 -> "200 OK"
        206 -> "206 Partial Content"
        other -> "#{other} Error"
      end

    response =
      IO.iodata_to_binary([
        "HTTP/1.1 ",
        status,
        "\r\nContent-Length: ",
        Integer.to_string(byte_size(resp_body)),
        extra,
        "\r\nConnection: close\r\n\r\n",
        resp_body
      ])

    :gen_tcp.send(socket, response)
  end

  defp range_response(request, body) do
    total = byte_size(body)

    case Regex.run(~r/Range: bytes=(\d+)-(\d+)/, request) do
      [_, start_s, end_s] ->
        start = String.to_integer(start_s)
        stop = min(String.to_integer(end_s), total - 1)
        slice = binary_part(body, start, stop - start + 1)

        extra =
          IO.iodata_to_binary([
            "\r\nContent-Range: bytes ",
            Integer.to_string(start),
            "-",
            Integer.to_string(stop),
            "/",
            Integer.to_string(total)
          ])

        {206, slice, extra}

      _ ->
        {200, body, ""}
    end
  end

  defp sample_torrent(hash, pieces_count, piece_len \\ 16_384) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "test", "piece length" => piece_len}},
      left: pieces_count * piece_len,
      last_index: pieces_count - 1,
      last_piece_length: piece_len,
      bitfield: Bitfield.make(pieces_count),
      peer_status: nil
    }
  end

  defp endgame_torrent(hash) do
    %Torrent{
      hash: hash,
      metadata: %{"info" => %{"name" => "endgame-pin", "piece length" => 16_384}},
      left: 5 * 16_384,
      last_index: 3,
      last_piece_length: 16_384,
      peer_status: nil
    }
  end

  defp both_pieces do
    Bitfield.make(4)
    |> Bitfield.set(0, 1)
    |> Bitfield.set(1, 1)
  end

  defp swarm_via(hash), do: {:via, Registry, {Registry, {hash, Swarm}}}

  defp downloads_via(hash), do: {:via, Registry, {Registry, {hash, Downloads}}}

  defp start_swarm(hash) do
    case DynamicSupervisor.start_link(name: swarm_via(hash), strategy: :one_for_one) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
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

  defp add_swarm_peer(hash, id, opts) do
    spec = %{
      id: {:mock_peer, id},
      start: {__MODULE__.MockPeer, :start_link, [hash, id]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(swarm_via(hash), spec)
    key = Peer.make_key(hash, id)
    _ = :sys.get_state({:via, Registry, {Registry, {key, Peer.Controller}}})

    pin_peer(key, opts)
    {pid, key}
  end

  defp pin_peer(key, opts) do
    now = System.monotonic_time(:millisecond)
    stale? = Keyword.get(opts, :stale, false)
    pinned_at = if stale?, do: now - @stale_ms - 1, else: now

    index = Keyword.get(opts, :index)

    status =
      case index do
        nil -> nil
        i -> i
      end

    :sys.replace_state({:via, Registry, {Registry, {key, Peer.Controller}}}, fn state ->
      %{
        state
        | bitfield: Keyword.fetch!(opts, :bitfield),
          status: status,
          choke_me: Keyword.get(opts, :choke_me, true),
          interested: true,
          pinned_at: pinned_at,
          pin_downloaded_bytes: 0
      }
    end)
  end

  defp await_uploader_task(task_pid) do
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _}, 5_000
  end

  defp sync_model(hash) do
    TestSupport.Sync.sync({:via, Registry, {Registry, {hash, Model}}})
  end

  defp await_webseed_tasks(pid, timeout \\ 5_000) do
    tasks = :sys.get_state(pid).tasks

    if map_size(tasks) == 0 do
      :ok
    else
      monitors = for {fetch_pid, _} <- tasks, do: {fetch_pid, Process.monitor(fetch_pid)}

      Enum.each(monitors, fn {fetch_pid, ref} ->
        assert_receive {:DOWN, ^ref, :process, ^fetch_pid, _}, timeout
      end)

      TestSupport.Sync.sync(pid)
      await_webseed_tasks(pid, timeout)
    end
  end

  defp safe_stop(pid) when is_pid(pid) do
    TestSupport.Sync.safe_stop(pid, 1_000)
  end
end

defmodule TorrentStorageCoverageBatchTest.MockPeer do
  @moduledoc false
  use GenServer

  @type t :: %{controller: pid()}

  @spec start_link(Torrent.hash(), Peer.id()) :: GenServer.on_start()
  def start_link(hash, id) do
    GenServer.start_link(__MODULE__, {hash, id})
  end

  @spec init({Torrent.hash(), Peer.id()}) :: {:ok, t()}
  def init({hash, id}) do
    key = Peer.make_key(hash, id)
    Registry.register(Registry, {key, Peer}, nil)

    {:ok, ctrl} =
      GenServer.start_link(
        Peer.Controller,
        [hash, id, nil, Peer.reserved()],
        name: {:via, Registry, {Registry, {key, Peer.Controller}}}
      )

    Process.monitor(ctrl)
    {:ok, %{controller: ctrl}}
  end

  @spec handle_info({:DOWN, reference(), :process, pid(), term()}, t()) ::
          {:stop, :normal, t()}
  def handle_info({:DOWN, _, :process, _ctrl, _}, state), do: {:stop, :normal, state}
end

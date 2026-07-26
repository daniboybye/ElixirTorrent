defmodule Peer.HashTransferTest do
  use ExUnit.Case, async: false

  alias Peer.{Controller, HashTransfer, HashWire}
  alias Peer.Controller.State
  alias Torrent.{FileHandle, Merkle}

  @block Merkle.block_size()
  @timeout 5_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "outbound correlation lifecycle" do
    test "duplicate exact request returns already_pending" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))
      req_key = HashTransfer.request_key(req)

      state =
        base_state(hash, peer_v2_support?: true)
        |> put_in(
          [Access.key!(:hash_requests), req_key],
          %{ref: make_ref(), request: req, caller: self(), timer: make_ref()}
        )

      assert {:error, :already_pending, _state} =
               State.start_hash_request(state, req, self(), @timeout)
    end

    test "caps distinct pending hash requests per peer" do
      hash = :crypto.strong_rand_bytes(20)

      pending =
        for index <- 0..7, into: %{} do
          req = sample_req(:crypto.strong_rand_bytes(32))
          ref = make_ref()

          {{req.pieces_root, 0, index, 2, 1},
           %{ref: ref, request: req, caller: self(), timer: make_ref()}}
        end

      state = %{base_state(hash, peer_v2_support?: true) | hash_requests: pending}
      req = sample_req(:crypto.strong_rand_bytes(32))

      assert {:error, :too_many_pending, ^state} =
               State.start_hash_request(state, req, self(), @timeout)
    end

    test "disconnect notifies pending callers" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))
      ref = make_ref()

      state =
        base_state(hash, peer_v2_support?: true)
        |> put_in(
          [Access.key!(:hash_requests), HashTransfer.request_key(req)],
          %{ref: ref, request: req, caller: self(), timer: make_ref()}
        )

      :ok = State.notify_hash_request_disconnect(state, :shutdown)
      assert_receive {:peer_hash_transfer, ^ref, {:disconnect, ^req}}, @timeout
    end

    test "outbound blocked when peer lacks v2 bit" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))
      state = base_state(hash, peer_v2_support?: false)

      assert {:error, :peer_not_v2, _state} =
               State.start_hash_request(state, req, self(), @timeout)
    end

    test "timeout drop notifies caller" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))
      ref = make_ref()
      caller = self()

      state =
        base_state(hash, peer_v2_support?: true)
        |> put_in(
          [Access.key!(:hash_requests), HashTransfer.request_key(req)],
          %{ref: ref, request: req, caller: caller, timer: make_ref()}
        )

      {pending, state} = State.drop_hash_request(state, ref)
      assert pending.request == req
      HashTransfer.notify(caller, ref, {:timeout, req})
      assert_receive {:peer_hash_transfer, ^ref, {:timeout, ^req}}, @timeout
      assert map_size(state.hash_requests) == 0
    end
  end

  describe "inbound hash_request serving" do
    test "unknown pieces root degrades to hash_reject without crashing" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))

      with_sender_stub(hash, fn _key ->
        state = base_state(hash)
        assert %State{} = State.handle_hash_request(state, req)
        assert_receive {:sent, {:hash_reject, rejected}}, @timeout
        assert rejected.pieces_root == req.pieces_root
      end)
    end

    test "leaf range hash_request does not gate on choke state" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))

      state =
        base_state(hash,
          choke: true,
          interested_of_me: false,
          peer_v2_support?: true
        )

      assert %State{} = State.handle_hash_request(state, req)
    end
  end

  describe "inbound hashes verification" do
    test "correlated bad proof count is protocol_error" do
      hash = :crypto.strong_rand_bytes(20)
      blocks = for byte <- [?a, ?b, ?c, ?d], do: :binary.copy(<<byte>>, @block)
      {:ok, tree} = Merkle.build(IO.iodata_to_binary(blocks))
      root = Merkle.root(tree)

      req = %HashWire{
        pieces_root: root,
        base_layer: 0,
        index: 0,
        length: 2,
        proof_layers: 1
      }

      with_model(hash, root, fn ->
        with_sender_stub(hash, fn _key ->
          ref = make_ref()

          state =
            base_state(hash, peer_v2_support?: true)
            |> put_in(
              [Access.key!(:hash_requests), HashTransfer.request_key(req)],
              %{ref: ref, request: req, caller: self(), timer: make_ref()}
            )

          short_blob = :binary.copy(<<0>>, 32 * 2)

          assert {:error, :protocol_error, _state} =
                   State.handle_hashes(state, req, short_blob)

          assert_receive {:peer_hash_transfer, ^ref, {:error, :protocol_error, ^req}}, @timeout
        end)
      end)
    end

    test "validate_outbound returns error without v2 context" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))

      assert {:error, :missing_v2_context} = Torrent.HashServe.validate_outbound(hash, req)
    end

    test "start_hash_request with missing v2 context does not crash controller" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))
      state = base_state(hash, peer_v2_support?: true)

      assert {:error, :missing_v2_context, _state} =
               State.start_hash_request(state, req, self(), @timeout)
    end

    test "HashServe rejects when task supervisor is at capacity" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))

      {:ok, sup} =
        Task.Supervisor.start_link(
          max_restarts: 0,
          max_children: Torrent.HashServe.max_tasks(),
          name: {:via, Registry, {Registry, {hash, Torrent.HashServe}}}
        )

      on_exit(fn ->
        try do
          if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 500)
        catch
          :exit, _ -> :ok
        end
      end)

      blockers =
        for _ <- 1..Torrent.HashServe.max_tasks() do
          {:ok, pid} =
            Task.Supervisor.start_child(
              {:via, Registry, {Registry, {hash, Torrent.HashServe}}},
              fn -> Process.sleep(30_000) end
            )

          pid
        end

      with_sender_stub(hash, fn _key ->
        state = base_state(hash)
        assert %State{} = State.handle_hash_request(state, req)
        assert_receive {:sent, {:hash_reject, rejected}}, @timeout
        assert rejected.pieces_root == req.pieces_root
      end)

      for pid <- blockers do
        Process.exit(pid, :kill)
      end
    end

    test "stale uncorrelated hashes response is ignored" do
      hash = :crypto.strong_rand_bytes(20)
      req = sample_req(:crypto.strong_rand_bytes(32))

      with_sender_stub(hash, fn _key ->
        state = base_state(hash, peer_v2_support?: true)
        blob = :binary.copy(<<0>>, 32 * HashWire.expected_hash_count(req))
        assert %State{} = State.handle_hashes(state, req, blob)
      end)
    end
  end

  describe "Controller.request_hashes exit mapping" do
    test "noproc when controller is gone" do
      hash = :crypto.strong_rand_bytes(20)
      id = Peer.id()
      key = Peer.make_key(hash, id)
      req = sample_req(:crypto.strong_rand_bytes(32))

      assert {:error, :noproc} = Controller.request_hashes(key, req, timeout: 100)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp sample_req(root) do
    %HashWire{
      pieces_root: root,
      base_layer: 0,
      index: 0,
      length: 2,
      proof_layers: 1
    }
  end

  defp base_state(hash, overrides \\ []) do
    id = Peer.id()

    struct!(
      %State{
        hash: hash,
        id: id,
        fast_extension: nil,
        status: nil,
        pieces_count: 1,
        socket: nil,
        choke: true,
        peer_v2_support?: false,
        hash_requests: %{}
      },
      overrides
    )
  end

  defp with_sender_stub(hash, fun) do
    id = Peer.id()
    key = Peer.make_key(hash, id)

    {:ok, stub} = HashTransferSentStub.start_link(key, self())

    on_exit(fn ->
      try do
        if Process.alive?(stub), do: GenServer.stop(stub, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)

    fun.(key)
  end

  defp with_model(hash, root, fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_hash_xfer_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "data.bin")
    File.write!(path, :binary.copy(<<?x>>, @block * 4))

    merkle = %{
      piece_length: @block * 4,
      files: [
        %{
          path: ["data.bin"],
          length: @block * 4,
          pieces_root: root,
          piece_hashes: [root]
        }
      ]
    }

    torrent = %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{"name" => "t", "piece length" => @block * 4, "length" => @block * 4}
      },
      left: @block * 4,
      last_index: 0,
      last_piece_length: @block * 4,
      download_dir: dir,
      kind: :hybrid,
      merkle: merkle
    }

    {:ok, model} = Torrent.Model.start_link(torrent)
    {:ok, _} = FileHandle.Store.start_link(hash)

    on_exit(fn ->
      for pid <- [model] do
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    fun.()
  end
end

defmodule Torrent.MerkleDiskServeTest do
  use ExUnit.Case, async: true

  alias Torrent.Merkle

  @block Merkle.block_size()

  test "leaf_range_response_from_disk matches in-memory tree for bounded request" do
    blocks = for i <- 0..15, do: :binary.copy(<<rem(i, 256)>>, @block)
    content = IO.iodata_to_binary(blocks)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)
    piece_length = 4 * @block
    {:ok, layer} = Merkle.piece_layer_level(piece_length)
    piece_hashes = tree.levels |> Enum.at(layer)

    dir = Path.join(System.tmp_dir!(), "merkle_disk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "big.bin")
    File.write!(path, content)

    on_exit(fn -> File.rm_rf!(dir) end)

    read_indices = Merkle.leaf_read_indices(16, piece_length, 0, 4, 3)
    assert length(read_indices) <= 16
    assert length(read_indices) >= 4

    assert {:ok, from_tree} = Merkle.range_response(tree, 0, 0, 4, 3)

    assert {:ok, from_disk} =
             Merkle.leaf_range_response_from_disk(
               path,
               byte_size(content),
               piece_hashes,
               piece_length,
               0,
               4,
               3
             )

    assert from_disk == from_tree
    assert Merkle.verify_hashes(root, 0, 0, 4, 3, from_disk, 16)
  end

  test "leaf_read_indices stays bounded on large virtual file" do
    block_count = 1024
    piece_length = 4 * @block
    indices = Merkle.leaf_read_indices(block_count, piece_length, 0, 2, 2)
    assert length(indices) < block_count
    assert 0 in indices and 1 in indices
  end
end

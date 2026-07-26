defmodule Peer.HashCorrelationIntegrationTest do
  use ExUnit.Case, async: false

  alias Peer.{Controller, HashWire}
  alias Peer.Controller.State
  alias Torrent.{FileHandle, Merkle, Model, PiecesStatistic}

  @block Merkle.block_size()
  @timeout 5_000
  @v2_reserved <<0, 0, 0, 0, 0, 16, 0, 21>>

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)
    :ok
  end

  test "manual relay: request_hashes through HashServe serve to verified caller notification" do
    {hash, root, _path, _piece_length, _piece_hashes, _content} = setup_v2_torrent!()

    req = %HashWire{
      pieces_root: root,
      base_layer: 0,
      index: 0,
      length: 4,
      proof_layers: 3
    }

    id_a = :crypto.strong_rand_bytes(20)
    key_a = Peer.make_key(hash, id_a)
    {:ok, stub_a} = HashTransferSentStub.start_link(key_a, self())
    {:ok, _ctrl_a} = start_controller(hash, id_a)

    on_exit(fn -> cleanup_stub(stub_a) end)

    assert {:ok, ref} = Controller.request_hashes(key_a, req, timeout: @timeout)
    assert_receive {:sent, {:hash_request, ^req}}, @timeout

    id_b = :crypto.strong_rand_bytes(20)
    key_b = Peer.make_key(hash, id_b)
    {:ok, stub_b} = HashTransferSentStub.start_link(key_b, self())

    on_exit(fn -> cleanup_stub(stub_b) end)

    state_b = %State{
      hash: hash,
      id: id_b,
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: nil,
      choke: true,
      peer_v2_support?: true,
      hash_requests: %{}
    }

    assert %State{} = State.handle_hash_request(state_b, req)
    assert_receive {:sent, {:hashes, ^req, blob}}, @timeout
    assert :ok = HashWire.validate_hashes_payload(req, blob)

    assert :ok = Controller.handle_hashes(key_a, req, blob)
    assert_receive {:peer_hash_transfer, ^ref, {:ok, ^req, hashes}}, @timeout
    assert Merkle.verify_hashes(root, 0, 0, 4, 3, hashes, 16)
  end

  test "correlated hash_reject notifies requester" do
    {hash, root, _, _, _, _} = setup_v2_torrent!()

    req = %HashWire{
      pieces_root: root,
      base_layer: 0,
      index: 0,
      length: 4,
      proof_layers: 3
    }

    id_a = :crypto.strong_rand_bytes(20)
    key_a = Peer.make_key(hash, id_a)
    {:ok, stub_a} = HashTransferSentStub.start_link(key_a, self())
    {:ok, _ctrl_a} = start_controller(hash, id_a)

    on_exit(fn -> cleanup_stub(stub_a) end)

    assert {:ok, ref} = Controller.request_hashes(key_a, req, timeout: @timeout)

    assert :ok = Controller.handle_hash_reject(key_a, req)
    assert_receive {:peer_hash_transfer, ^ref, {:reject, ^req}}, @timeout
  end

  test "inbound hash_request without v2 context rejects without crash" do
    hash = :crypto.strong_rand_bytes(20)

    req = %HashWire{
      pieces_root: :crypto.strong_rand_bytes(32),
      base_layer: 0,
      index: 0,
      length: 2,
      proof_layers: 1
    }

    id = Peer.id()
    key = Peer.make_key(hash, id)
    {:ok, stub} = HashTransferSentStub.start_link(key, self())

    on_exit(fn -> cleanup_stub(stub) end)

    state = %State{
      hash: hash,
      id: id,
      fast_extension: nil,
      status: nil,
      pieces_count: 1,
      socket: nil,
      choke: true,
      peer_v2_support?: false,
      hash_requests: %{}
    }

    assert %State{} = State.handle_hash_request(state, req)
    assert_receive {:sent, {:hash_reject, rejected}}, @timeout
    assert rejected == req
  end

  ## helpers -----------------------------------------------------------------

  defp setup_v2_torrent! do
    blocks =
      for byte <- [?a, ?b, ?c, ?d, ?e, ?f, ?g, ?h, ?i, ?j, ?k, ?l, ?m, ?n, ?o, ?p],
          do: :binary.copy(<<byte>>, @block)

    content = IO.iodata_to_binary(blocks)
    {:ok, tree} = Merkle.build(content)
    root = Merkle.root(tree)
    piece_length = 4 * @block
    {:ok, layer} = Merkle.piece_layer_level(piece_length)
    piece_hashes = tree.levels |> Enum.at(layer)

    hash = :crypto.strong_rand_bytes(20)

    dir =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_hash_corr_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "data.bin")
    File.write!(path, content)

    on_exit(fn -> File.rm_rf!(dir) end)

    merkle = %{
      piece_length: piece_length,
      files: [
        %{
          path: ["data.bin"],
          length: byte_size(content),
          pieces_root: root,
          piece_hashes: piece_hashes
        }
      ]
    }

    torrent = %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => "data.bin",
          "piece length" => piece_length,
          "length" => byte_size(content)
        }
      },
      left: byte_size(content),
      last_index: 0,
      last_piece_length: byte_size(content),
      download_dir: dir,
      kind: :hybrid,
      merkle: merkle
    }

    :ok = PiecesStatistic.init(torrent)
    {:ok, model} = Model.start_link(torrent)
    {:ok, store} = FileHandle.Store.start_link(hash)

    {:ok, hash_sup} =
      Task.Supervisor.start_link(
        max_restarts: 0,
        max_children: Torrent.HashServe.max_tasks(),
        name: {:via, Registry, {Registry, {hash, Torrent.HashServe}}}
      )

    on_exit(fn ->
      for pid <- [model, store, hash_sup] do
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {hash, root, path, piece_length, piece_hashes, content}
  end

  defp start_controller(hash, id) do
    key = Peer.make_key(hash, id)

    GenServer.start(
      Peer.Controller,
      [hash, id, nil, @v2_reserved],
      name: {:via, Registry, {Registry, {key, Peer.Controller}}}
    )
  end

  defp cleanup_stub(stub) do
    if Process.alive?(stub), do: GenServer.stop(stub, :normal, 500)
  catch
    :exit, _ -> :ok
  end
end

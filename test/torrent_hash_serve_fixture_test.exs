defmodule Torrent.HashServeFixtureTest do
  use ExUnit.Case, async: false

  alias Peer.HashWire
  alias Torrent.{FileHandle, HashServe, Merkle, Model}

  @timeout 5_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    fixture = Path.join([__DIR__, "fixtures", "libtorrent_v2_multipiece_file.torrent"])

    dir =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_hash_fixture_#{System.unique_integer([:positive])}"
      )

    torrent = fixture |> Torrent.parse_file!() |> Map.put(:download_dir, dir)
    :ok = Torrent.PiecesStatistic.init(torrent)
    {:ok, model} = Model.start_link(torrent)
    {:ok, store} = FileHandle.Store.start_link(torrent.hash)

    {:ok, hash_sup} =
      Task.Supervisor.start_link(
        max_restarts: 0,
        max_children: HashServe.max_tasks(),
        name: {:via, Registry, {Registry, {torrent.hash, HashServe}}}
      )

    sender_key = Peer.make_key(torrent.hash, :crypto.strong_rand_bytes(20))
    {:ok, sender} = HashTransferSentStub.start_link(sender_key, self())

    on_exit(fn ->
      for pid <- [sender, hash_sup, store, model] do
        try do
          TestSupport.Sync.safe_stop(pid, 2_000)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(dir)
    end)

    %{torrent: torrent, sender_key: sender_key}
  end

  test "serves libtorrent's real hybrid piece and leaf layers", %{
    torrent: torrent,
    sender_key: sender_key
  } do
    [%{pieces_root: root}] = torrent.merkle.files
    block_count = Merkle.file_block_count(1_048_576)
    {:ok, piece_layer} = Merkle.piece_layer_level(torrent.merkle.piece_length)

    piece_request = %HashWire{
      pieces_root: root,
      base_layer: piece_layer,
      index: 0,
      length: 4,
      proof_layers: 3
    }

    assert :ok = serve_and_verify(torrent.hash, sender_key, piece_request, root, block_count)

    leaf_request = %HashWire{
      pieces_root: root,
      base_layer: 0,
      index: 0,
      length: 4,
      proof_layers: 5
    }

    assert :ok = serve_and_verify(torrent.hash, sender_key, leaf_request, root, block_count)
  end

  defp serve_and_verify(hash, sender_key, request, root, block_count) do
    test_pid = self()

    :ok =
      HashServe.serve(hash, request, sender_key, fn response ->
        send(test_pid, {:hash_serve_response, request, response})
      end)

    assert_receive {:hash_serve_response, ^request, {:hashes, hashes}}, @timeout

    if Merkle.verify_hashes(
         root,
         request.base_layer,
         request.index,
         request.length,
         request.proof_layers,
         hashes,
         block_count
       ),
       do: :ok,
       else: :invalid_proof
  end
end

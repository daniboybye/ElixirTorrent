defmodule CorruptPieceSourceTest do
  @moduledoc """
  A peer that serves data failing the BEP 3 piece hash must be attributable and,
  after repeated offences, dropped. Without that the piece picker hands the same
  index straight back to the same peer and the torrent re-downloads it forever.
  """

  use ExUnit.Case, async: true

  alias Peer.Controller.State, as: ControllerState
  alias Torrent.Downloads.Piece

  @piece_len 4 * Piece.max_length()

  defp piece_state(hash) do
    %Piece.State{index: 7, hash: hash, waiting: []}
  end

  defp with_blocks(%Piece.State{} = state, blocks) do
    Enum.reduce(blocks, state, fn {peer_id, count}, %Piece.State{} = acc ->
      %Piece.State{acc | contributors: Map.put(acc.contributors, peer_id, count)}
    end)
  end

  describe "attributing a failed piece" do
    setup do
      {:ok, hash: :crypto.strong_rand_bytes(20)}
    end

    test "a piece assembled from one peer names that peer", %{hash: hash} do
      state = with_blocks(piece_state(hash), [{"peer-a", 64}])

      assert Piece.State.sole_contributor(state) == "peer-a"
    end

    test "a piece assembled from several peers names none of them", %{hash: hash} do
      state = with_blocks(piece_state(hash), [{"peer-a", 60}, {"peer-b", 4}])

      assert Piece.State.sole_contributor(state) == nil
    end

    test "a piece with no accepted blocks names no one", %{hash: hash} do
      assert Piece.State.sole_contributor(piece_state(hash)) == nil
    end
  end

  describe "recording block sources" do
    setup do
      hash = :crypto.strong_rand_bytes(20)
      dir = Path.join(System.tmp_dir!(), "corrupt_src_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      torrent = %Torrent{
        hash: hash,
        metadata: %{
          "info" => %{
            "name" => "t.bin",
            "piece length" => @piece_len,
            "length" => @piece_len,
            "pieces" => :crypto.strong_rand_bytes(20)
          }
        },
        left: @piece_len,
        last_index: 0,
        last_piece_length: @piece_len,
        download_dir: dir
      }

      {:ok, model} = Torrent.Model.start_link(torrent)
      :ok = Torrent.PiecesStatistic.init(torrent)
      files = start_supervised!({Torrent.FileHandle, hash})

      on_exit(fn ->
        TestSupport.Sync.safe_stop(files, 1_000)
        TestSupport.Sync.safe_stop(model, 1_000)
      end)

      {:ok, hash: hash}
    end

    test "an accepted block credits the peer that sent it", %{hash: hash} do
      len = Piece.max_length()
      block = :binary.copy(<<1>>, len)

      state =
        %Piece.State{index: 0, hash: hash, waiting: [{0, len}, {len, len}], mode: nil}
        |> Piece.State.response("peer-a", 0, block)

      assert state.contributors == %{"peer-a" => 1}
      assert Piece.State.sole_contributor(state) == "peer-a"

      state = Piece.State.response(state, "peer-b", len, block)

      assert state.contributors == %{"peer-a" => 1, "peer-b" => 1}
      assert Piece.State.sole_contributor(state) == nil
    end

    test "a block for a subpiece nobody asked for credits no one", %{hash: hash} do
      block = :binary.copy(<<1>>, Piece.max_length())

      state =
        %Piece.State{index: 0, hash: hash, waiting: [], mode: nil}
        |> Piece.State.response("peer-a", 0, block)

      assert state.contributors == %{}
      assert Piece.State.sole_contributor(state) == nil
    end

    test "a block outside the piece credits no one", %{hash: hash} do
      block = :binary.copy(<<1>>, Piece.max_length())

      state =
        %Piece.State{index: 0, hash: hash, waiting: [{@piece_len, Piece.max_length()}], mode: nil}
        |> Piece.State.response("peer-a", @piece_len, block)

      assert state.contributors == %{}
    end
  end

  describe "peer strikes" do
    setup do
      hash = :crypto.strong_rand_bytes(20)

      state = %ControllerState{
        hash: hash,
        id: Peer.id(),
        fast_extension: nil,
        status: nil,
        pieces_count: 16,
        socket: nil
      }

      {:ok, state: state}
    end

    test "enough distinct bad pieces disconnects the peer", %{state: state} do
      limit = ControllerState.max_hash_failures()

      final =
        Enum.reduce(1..(limit - 1), state, fn index, acc ->
          assert %ControllerState{hash_failures: failures} =
                   next = ControllerState.hash_check_failed(acc, index)

          assert MapSet.size(failures) == index
          next
        end)

      assert {:error, :corrupt_pieces, %ControllerState{}} =
               ControllerState.hash_check_failed(final, limit)
    end

    test "a local race on one piece does not cost a good peer its connection", %{state: state} do
      assert %ControllerState{hash_failures: failures} =
               ControllerState.hash_check_failed(state, 3)

      assert MapSet.member?(failures, 3)
    end

    test "a poisoned piece is never requested from that peer again", %{state: state} do
      state = ControllerState.hash_check_failed(state, 226)

      unchoked =
        ControllerState.handle_unchoke(%ControllerState{
          state
          | status: 226,
            interested: true,
            choke_me: true
        })

      # The pin is dropped instead of re-requested, so the peer can move to a
      # piece it has not already ruined.
      assert unchoked.status == nil
    end

    test "the same bad piece twice is still one bad piece", %{state: state} do
      limit = ControllerState.max_hash_failures()

      final =
        Enum.reduce(1..(limit + 2), state, fn _, acc ->
          assert %ControllerState{} = next = ControllerState.hash_check_failed(acc, 226)
          next
        end)

      assert MapSet.to_list(final.hash_failures) == [226]
    end
  end
end

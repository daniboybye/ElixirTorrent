defmodule Torrent.ModelEndgameTest do
  use ExUnit.Case, async: false

  alias Torrent.Bitfield
  alias Torrent.Model

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  @piece_len 16_384
  @total_pieces 20

  test "mode is nil when more than @until_endgame piece-lengths remain" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = torrent_with_missing_pieces(hash, 11)

    assert {:ok, pid} = Model.start_link(torrent)
    on_exit(fn -> stop_model(pid) end)

    assert Model.get(hash, :mode) == nil
  end

  test "mode is endgame when at most @until_endgame piece-lengths remain" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = torrent_with_missing_pieces(hash, 10)

    assert {:ok, pid} = Model.start_link(torrent)
    on_exit(fn -> stop_model(pid) end)

    assert Model.get(hash, :mode) == :endgame
  end

  test "mode is nil when download is complete" do
    hash = :crypto.strong_rand_bytes(20)
    torrent = torrent_with_missing_pieces(hash, 0)

    assert {:ok, pid} = Model.start_link(torrent)
    on_exit(fn -> stop_model(pid) end)

    assert Model.get(hash, :mode) == nil
  end

  defp torrent_with_missing_pieces(hash, missing_count) do
    have_count = @total_pieces - missing_count

    bitfield =
      Enum.reduce(0..(have_count - 1), Bitfield.make(@total_pieces), fn index, bf ->
        Bitfield.set(bf, index, 1)
      end)

    %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => "endgame-threshold",
          "length" => @total_pieces * @piece_len,
          "piece length" => @piece_len,
          "pieces" => :binary.copy(<<0::160>>, @total_pieces)
        }
      },
      left: 0,
      last_index: @total_pieces - 1,
      last_piece_length: @piece_len,
      bitfield: bitfield
    }
    |> Model.reconcile_progress()
  end

  defp stop_model(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end
end

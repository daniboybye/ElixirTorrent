defmodule Torrent.PiecesStatistic do
  @type index :: Torrent.index() | nil
  @type status :: :allowed_fast | :complete | :processing | nil
  @typep element :: {Torrent.index(), non_neg_integer(), status()}

  @the_rarest 7

  @spec init(Torrent.t()) :: :ok
  def init(%Torrent{hash: hash, last_index: count}) do
    ref = :ets.new(nil, [:set, :public, keypos: 1, write_concurrency: true])
    Registry.register(Registry, key(hash), ref)
    true = :ets.insert(ref, Enum.map(0..count, &{&1, 0, nil}))
    :ok
  end

  @spec choice_piece(Torrent.hash(), :random | :rare) :: index()
  def choice_piece(hash, :random) do
    table_ref(hash)
    |> :ets.select([
      {{:"$0", :"$1", :"$2"},
       [
         {:andalso, {:>, :"$1", 0},
          {:orelse, {:"=:=", :"$2", nil}, {:"=:=", :"$2", :allowed_fast}}}
       ], [:"$0"]}
    ])
    |> (&unless(Enum.empty?(&1), do: Enum.random(&1))).()
  end

  def choice_piece(hash, :rare) do
    case :ets.foldl(&choice_rare/2, nil, table_ref(hash)) do
      nil ->
        nil

      {index, :allowed_fast} ->
        index

      list ->
        list
        |> Enum.random()
        |> elem(0)
    end
  end

  @spec set(Torrent.hash(), Torrent.index(), status()) :: :ok
  def set(hash, index, status) do
    true = :ets.update_element(table_ref(hash), index, {3, status})
    :ok
  end

  @spec inc(Torrent.hash(), Torrent.index()) :: :ok
  def inc(hash, index) do
    update_counter(table_ref(hash), index)
    :ok
  end

  @spec update(Torrent.hash(), Torrent.bitfield(), non_neg_integer()) :: :ok
  def update(hash, bitfield, size) do
    indices_inc(bitfield, size, table_ref(hash))
  end

  @spec inc_all(Torrent.hash(), Torrent.index()) :: :ok
  def inc_all(hash, last_index) do
    ref = table_ref(hash)
    Enum.each(0..last_index, &update_counter(ref, &1))
  end

  defp update_counter(ref, index) do
    :ets.update_counter(ref, index, 1)
  end

  defp indices_inc(bin, size, ref, index \\ 0)

  defp indices_inc(_, size, _, index) when size == index, do: :ok

  defp indices_inc(<<x::1, bin::bits>>, size, ref, index) do
    if x == 1, do: update_counter(ref, index)

    indices_inc(bin, size, ref, index + 1)
  end

  defp key(hash), do: {hash, __MODULE__}

  defp table_ref(hash) do
    [{_pid, ref}] = Registry.lookup(Registry, key(hash))
    ref
  end

  defp choice_rare(_, {_, :allowed_fast} = acc), do: acc

  defp choice_rare({_, 0, _}, acc), do: acc

  defp choice_rare({index, _, :allowed_fast}, _), do: {index, :allowed_fast}

  defp choice_rare({_, _, status}, acc) when status in [:complete, :processing],
    do: acc

  defp choice_rare({index, n, _}, nil), do: [{index, n}]

  defp choice_rare({index, n, _}, acc) do
    list = [{index, n} | acc]

    case Enum.count(acc) do
      @the_rarest ->
        maximum = Enum.max_by(list, &elem(&1, 1))
        List.delete(list, maximum)

      _ ->
        list
    end
  end
end

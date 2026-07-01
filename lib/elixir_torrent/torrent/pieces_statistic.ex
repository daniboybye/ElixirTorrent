defmodule Torrent.PiecesStatistic do
  @type index :: Torrent.index() | nil
  @type status :: :allowed_fast | :complete | :processing | nil

  @the_rarest 7

  @spec init(Torrent.t()) :: :ok
  def init(%Torrent{hash: hash, last_index: count}) do
    case Registry.lookup(Registry, key(hash)) do
      [{_pid, ref}] when is_reference(ref) ->
        :ok

      [] ->
        ref = :ets.new(nil, [:set, :public, keypos: 1, write_concurrency: true])
        true = :ets.insert(ref, Enum.map(0..count, &{&1, 0, nil}))

        case Registry.register(Registry, key(hash), ref) do
          {:ok, _} ->
            :ok

          {:error, {:already_registered, _pid}} ->
            :ets.delete(ref)
            :ok
        end
    end
  end

  @spec choice_piece(Torrent.hash(), :random | :rare, keyword()) :: index()
  def choice_piece(hash, strategy, opts \\ [])

  def choice_piece(hash, :random, opts) do
    exclude = MapSet.new(Keyword.get(opts, :exclude, []))

    table_ref(hash)
    |> :ets.select([
      {{:"$0", :"$1", :"$2"},
       [
         {:andalso, {:>, :"$1", 0},
          {:orelse, {:"=:=", :"$2", nil}, {:"=:=", :"$2", :allowed_fast}}}
       ], [:"$0"]}
    ])
    |> Enum.reject(&MapSet.member?(exclude, &1))
    |> case do
      [] -> nil
      indices -> Enum.random(indices)
    end
  end

  def choice_piece(hash, :rare, opts) do
    exclude = MapSet.new(Keyword.get(opts, :exclude, []))

    case :ets.foldl(&choice_rare/2, nil, table_ref(hash)) do
      nil ->
        nil

      list ->
        list
        |> Enum.reject(fn {index, _} -> MapSet.member?(exclude, index) end)
        |> case do
          [] -> nil
          filtered -> filtered |> Enum.random() |> elem(0)
        end
    end
  end

  @doc """
  Clears stale `:processing` marks left when a piece worker exited without finishing.
  """
  @spec reconcile_stale_statuses(Torrent.hash(), (Torrent.index() -> boolean())) :: non_neg_integer()
  def reconcile_stale_statuses(hash, piece_active?) when is_function(piece_active?, 1) do
    [count] = Torrent.get(hash, [:pieces_count])

    Enum.reduce(0..(count - 1), 0, fn index, cleared ->
      if get_status(hash, index) == :processing and not piece_active?.(index) do
        set(hash, index, nil)
        cleared + 1
      else
        cleared
      end
    end)
  end

  @spec reset_availability(Torrent.hash(), Torrent.index()) :: :ok
  def reset_availability(hash, index) do
    true = :ets.update_element(table_ref(hash), index, {2, 0})
    :ok
  end

  @spec set(Torrent.hash(), Torrent.index(), status()) :: :ok
  def set(hash, index, status) do
    true = :ets.update_element(table_ref(hash), index, {3, status})
    :ok
  end

  @spec inc(Torrent.hash(), Torrent.index()) :: :ok
  def inc(hash, index) do
    inc_counter(table_ref(hash), index)
    :ok
  end

  @spec dec(Torrent.hash(), Torrent.index()) :: :ok
  def dec(hash, index) do
    dec_counter(table_ref(hash), index)
    :ok
  end

  @spec update(Torrent.hash(), Torrent.bitfield(), non_neg_integer()) :: :ok
  def update(hash, bitfield, size),
    do: indices_inc(bitfield, size, table_ref(hash))

  @spec inc_all(Torrent.hash(), Torrent.index()) :: :ok
  def inc_all(hash, last_index) do
    ref = table_ref(hash)
    Enum.each(0..last_index, &inc_counter(ref, &1))
    :ok
  end

  @spec dec_all(Torrent.hash(), Torrent.index()) :: :ok
  def dec_all(hash, last_index) do
    ref = table_ref(hash)
    Enum.each(0..last_index, &dec_counter(ref, &1))
    :ok
  end

  @spec remove_peer(Torrent.hash(), Torrent.bitfield() | :all | :none | nil, pos_integer()) :: :ok
  def remove_peer(_hash, nil, _pieces_count), do: :ok
  def remove_peer(_hash, :none, _pieces_count), do: :ok

  def remove_peer(hash, :all, pieces_count) do
    dec_all(hash, pieces_count - 1)
  end

  def remove_peer(hash, bitfield, pieces_count) when is_binary(bitfield) do
    indices_dec(bitfield, pieces_count, table_ref(hash))
  end

  @spec availability(Torrent.hash(), Torrent.index()) :: non_neg_integer()
  def availability(hash, index) do
    :ets.lookup_element(table_ref(hash), index, 2)
  catch
    :exit, _ -> 0
  end

  def get_status(hash, index),
    do: :ets.lookup_element(table_ref(hash), index, 3)

  def have?(hash, index), do: get_status(hash, index) === :complete

  def i(hash), do: :ets.i(table_ref(hash))

  # def pieces_for_check(hash) do
  #   :ets.select(table_ref(hash),[
  #     {{:"$1", :"$2", :_},
  #     [{:orelse, {:"=:=", :"$2", :processing}, {:"=:=", :"$2", :complete}}],
  #     [:"$1"]}
  #   ])
  # end

  # @spec to_file!(Torrent.hash()) :: :ok
  # def to_file!(hash) do
  #   file_name = hash <> ".bin"
  #   File.touch!(file_name)
  #   :ok = :ets.tab2file(table_ref(hash), file_name) 
  # end

  defp inc_counter(ref, index),
    do: :ets.update_counter(ref, index, 1)

  defp dec_counter(ref, index),
    do: :ets.update_counter(ref, index, {2, -1, 0, 0})

  defp indices_inc(bin, size, ref, index \\ 0)

  defp indices_inc(_, size, _, index) when size == index, do: :ok

  defp indices_inc(<<x::1, bin::bits>>, size, ref, index) do
    if x == 1, do: inc_counter(ref, index)

    indices_inc(bin, size, ref, index + 1)
  end

  defp indices_dec(bin, size, ref, index \\ 0)

  defp indices_dec(_, size, _, index) when size == index, do: :ok

  defp indices_dec(<<x::1, bin::bits>>, size, ref, index) do
    if x == 1, do: dec_counter(ref, index)

    indices_dec(bin, size, ref, index + 1)
  end

  defp key(hash), do: {__MODULE__, hash}

  defp table_ref(hash) do
    [{_pid, ref}] = Registry.lookup(Registry, key(hash))
    ref
  end

  defp choice_rare({_, _, status}, acc) when status in [:complete, :processing],
    do: acc

  # Never select a piece with availability counter == 0
  defp choice_rare({_, 0, _}, nil), do: nil

  defp choice_rare({index, n, _}, nil), do: [{index, n}]

  defp choice_rare({_, 0, _}, acc), do: acc

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

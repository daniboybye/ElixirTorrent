defmodule AllowedFast do
  # denote the final number of pieces in the allowed fast set
  @k 10

  @type set :: MapSet.t(Torrent.index())

  # Elixir 1.20's MapSet implementation and published opaque :sets type disagree
  # about the empty set's internal map representation. We only use MapSet's
  # public API, so this is an analyzer false positive rather than an opacity leak.
  @dialyzer {:no_opaque, set: 4}

  @spec count() :: non_neg_integer()
  def count, do: @k

  @spec new() :: set()
  def new, do: MapSet.new()

  @spec set(:inet.ip_address(), Torrent.hash(), Torrent.index(), non_neg_integer()) :: set()
  def set(ip, hash, torrent_size, set_size \\ count())

  def set({ip1, ip2, ip3, _}, hash, torrent_size, set_size) do
    bin = <<ip1, ip2, ip3, 0, hash::binary>>

    new_indexies(new(), bin, torrent_size, set_size)
  end

  def set({s1, s2, s3, _s4, _s5, _s6, _s7, _s8}, hash, torrent_size, set_size) do
    bin = <<s1::16, s2::16, s3::16, 0::80, hash::binary>>

    new_indexies(new(), bin, torrent_size, set_size)
  end

  def set(_, _, _, _), do: new()

  @spec new_indexies(set(), Torrent.hash(), Torrent.index(), non_neg_integer()) :: set()
  defp new_indexies(set, bin, torrent_size, set_size) do
    case MapSet.size(set) do
      ^set_size ->
        set

      _ ->
        bin = :crypto.hash(:sha, bin)
        <<n1::32, n2::32, n3::32, n4::32, n5::32>> = bin

        [n1, n2, n3, n4, n5]
        |> Enum.reduce_while(
          set,
          &case MapSet.size(&2) do
            ^set_size ->
              {:halt, &2}

            _ ->
              {:cont, MapSet.put(&2, Integer.mod(&1, torrent_size))}
          end
        )
        |> new_indexies(bin, torrent_size, set_size)
    end
  end
end

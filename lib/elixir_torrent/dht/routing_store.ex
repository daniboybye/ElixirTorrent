defmodule DHT.RoutingStore do
  @moduledoc """
  Persists DHT routing-table contacts across restarts.

  BEP 5 defines no wire format for saved routing state; this is the analogue of
  libtorrent's `dht_state`. On shutdown (and periodically) we snapshot the known
  contacts to disk; on boot we reload them so the node rejoins the DHT
  immediately instead of waiting on a full bootstrap from the routers.

  Reloaded contacts are inserted as `:questionable` — after a restart we haven't
  heard from them this session, so the normal refresh/ping cycle re-verifies and
  evicts the stale ones (BEP 5 § node health). Bootstrap still runs in parallel
  as a fallback in case every saved node is gone.
  """

  alias DHT.{BEP42, RoutingTable, RoutingTables}

  require Logger

  @filename "dht_routing_table.bin"
  @format_version 1
  @max_per_family 400

  @doc """
  Persistence path, resolved at RUNTIME against the current working directory
  (the app's data dir). Must not be a compile-time module attribute — that would
  bake in the build machine's cwd and break persistence on any other host.
  """
  @spec path() :: Path.t()
  def path, do: Path.join([File.cwd!(), ".elixir_torrent", @filename])

  @doc """
  Snapshot both routing tables to disk. Never raises — a persistence hiccup must
  not disturb the DHT server.
  """
  @spec save(RoutingTables.t()) :: :ok
  def save(%{v4: v4, v6: v6}) do
    payload = %{
      version: @format_version,
      v4: contacts(v4),
      v6: contacts(v6)
    }

    file = path()
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, :erlang.term_to_binary(payload))
    :ok
  rescue
    error ->
      Logger.debug("[dht] routing_table save failed error=#{Exception.message(error)}")
      :ok
  end

  @doc """
  Seed `tables` with any persisted contacts. Returns the tables unchanged when
  the file is missing, unreadable, or from an unknown format version.
  """
  @spec load(RoutingTables.t()) :: RoutingTables.t()
  def load(tables) do
    with {:ok, bin} <- File.read(path()),
         {:ok, %{version: @format_version, v4: v4, v6: v6}} <- decode(bin) do
      seeded = seed(tables, List.wrap(v4) ++ List.wrap(v6))

      Logger.info(
        "[dht] routing_table restored v4=#{count(v4)} v6=#{count(v6)} seeded=#{RoutingTables.node_count(seeded)}"
      )

      seeded
    else
      _ -> tables
    end
  end

  @spec contacts(RoutingTable.t()) :: [%{id: binary(), ip: tuple(), port: non_neg_integer()}]
  defp contacts(%RoutingTable{} = table) do
    table
    |> RoutingTable.entries()
    |> Enum.take(@max_per_family)
    |> Enum.map(fn %{id: id, ip: ip, port: port} -> %{id: id, ip: ip, port: port} end)
  end

  @spec decode(binary()) :: {:ok, map()} | :error
  defp decode(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  @spec seed(RoutingTables.t(), [map()]) :: RoutingTables.t()
  defp seed(tables, contacts) do
    Enum.reduce(contacts, tables, fn contact, acc ->
      if valid_contact?(contact) and BEP42.valid_or_exempt?(contact.id, contact.ip) do
        RoutingTables.insert(acc, Map.take(contact, [:id, :ip, :port]), status: :questionable)
      else
        acc
      end
    end)
  end

  @spec valid_contact?(term()) :: boolean()
  defp valid_contact?(%{id: id, ip: ip, port: port})
       when is_binary(id) and byte_size(id) == 20 and is_integer(port) and port in 1..65_535 do
    tuple_size(ip) in [4, 8]
  end

  defp valid_contact?(_), do: false

  defp count(list) when is_list(list), do: length(list)
  defp count(_), do: 0
end

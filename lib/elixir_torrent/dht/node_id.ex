defmodule DHT.NodeId do
  @moduledoc """
  BEP 5 § Overview — 160-bit node id in the same space as info hashes.

  A random id is generated on first run and persisted under
  `.elixir_torrent/dht_node_id.bin` so restarts keep a stable routing identity.
  BEP 42 (deterministic id from IP) is not implemented; see TODO.txt.
  """

  @id_bits 160
  @path Path.join([File.cwd!(), ".elixir_torrent", "dht_node_id.bin"])

  @type t :: <<_::160>>

  @doc "Load persisted node id or create and persist a new random id."
  @spec get() :: t()
  def get do
    case File.read(@path) do
      {:ok, <<id::binary-size(20)>>} ->
        id

      _ ->
        id = :crypto.strong_rand_bytes(20)
        File.mkdir_p!(Path.dirname(@path))
        :ok = File.write(@path, id)
        id
    end
  end

  @doc "Return the persistence path (for tests)."
  @spec path() :: Path.t()
  def path, do: @path

  @doc false
  @spec id_bits() :: pos_integer()
  def id_bits, do: @id_bits
end

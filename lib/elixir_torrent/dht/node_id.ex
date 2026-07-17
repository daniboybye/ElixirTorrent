defmodule DHT.NodeId do
  @moduledoc """
  BEP 5 § Overview — 160-bit node id in the same space as info hashes.

  A random id is generated on first run and persisted under
  `.elixir_torrent/dht_node_id.bin` so restarts keep a stable routing identity.
  BEP 42 (deterministic id from IP) is not implemented; see TODO.txt.
  """

  @id_bits 160
  @filename "dht_node_id.bin"

  @type t :: <<_::160>>

  @doc "Load persisted node id or create and persist a new random id."
  @spec get() :: t()
  def get do
    file = path()

    case File.read(file) do
      {:ok, <<id::binary-size(20)>>} ->
        id

      _ ->
        id = :crypto.strong_rand_bytes(20)
        File.mkdir_p!(Path.dirname(file))
        :ok = File.write(file, id)
        id
    end
  end

  @doc """
  Persistence path, resolved at RUNTIME against the current working directory.

  This must be a function, not a compile-time module attribute: a `@path` set to
  `File.cwd!()` captures the *build* machine's directory, so on any other host
  the id file is never found and a fresh id is generated every launch (and on the
  build machine it silently writes into the source tree).
  """
  @spec path() :: Path.t()
  def path, do: Path.join([File.cwd!(), ".elixir_torrent", @filename])

  @doc false
  @spec id_bits() :: pos_integer()
  def id_bits, do: @id_bits
end

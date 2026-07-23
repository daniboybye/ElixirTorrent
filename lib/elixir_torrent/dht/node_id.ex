defmodule DHT.NodeId do
  @moduledoc """
  BEP 5 § Overview — 160-bit node id in the same space as info hashes.

  IDs are BEP-42–bound to the node's primary global IP when one is known
  (CRC32C prefix + persisted random tail). Falls back to a fully random id on
  loopback-only / unknown-IP boots. Persisted under `.elixir_torrent/dht_node_id.bin`.
  """

  alias DHT.BEP42

  @id_bits 160
  @filename "dht_node_id.bin"

  @type t :: <<_::160>>

  @doc "Load persisted node id or create and persist a new BEP-42 id."
  @spec get() :: t()
  def get do
    file = path()
    ip = primary_ip()

    case File.read(file) do
      {:ok, <<id::binary-size(20)>>} when is_tuple(ip) ->
        if BEP42.valid?(id, ip), do: id, else: write_id(file, regenerate(id, ip))

      {:ok, <<id::binary-size(20)>>} ->
        id

      _ ->
        write_id(file, fresh_id(ip))
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

  defp primary_ip do
    ips = Acceptor.primary_ips()

    cond do
      is_tuple(ips.inet6) -> ips.inet6
      is_tuple(ips.inet) -> ips.inet
      true -> nil
    end
  rescue
    _ -> nil
  end

  defp fresh_id(nil), do: :crypto.strong_rand_bytes(20)

  defp fresh_id(ip) do
    rand = :crypto.strong_rand_bytes(1) |> :binary.at(0)
    BEP42.generate(ip, rand, :crypto.strong_rand_bytes(16))
  end

  defp regenerate(<<_::binary-size(20)>> = old, ip) do
    <<_::binary-size(3), middle::binary-size(16), rand_byte::8>> = old
    BEP42.generate(ip, rand_byte, middle)
  end

  defp write_id(file, id) do
    File.mkdir_p!(Path.dirname(file))
    :ok = File.write(file, id)
    id
  end
end

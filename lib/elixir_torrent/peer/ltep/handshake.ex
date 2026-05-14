defmodule Peer.LTEP.Handshake do
  @moduledoc """
  BEP 10 extension handshake dictionary — encode, decode, and merge.

  The handshake payload is a bencoded dictionary sent as LTEP extended message id 0
  (BEP 10 § handshake message). All keys are optional; unknown keys are ignored for
  forward compatibility.
  """

  @enforce_keys []
  defstruct m: %{},
            p: nil,
            v: nil,
            yourip: nil,
            ipv4: nil,
            ipv6: nil,
            reqq: nil,
            metadata_size: nil,
            # libtorrent LTEP `e` — 1 means the peer supports protocol encryption (MSE/PE).
            e: nil

  @type t :: %__MODULE__{
          m: %{String.t() => non_neg_integer()},
          p: :inet.port_number() | nil,
          v: String.t() | nil,
          yourip: binary() | nil,
          ipv4: binary() | nil,
          ipv6: binary() | nil,
          reqq: pos_integer() | nil,
          metadata_size: pos_integer() | nil,
          e: 1 | nil
        }

  @doc """
  Decodes a bencoded handshake dictionary into a `%Peer.LTEP.Handshake{}`.

  Malformed or non-dictionary payloads return `{:error, :invalid_handshake}`.
  Unknown top-level keys are dropped (BEP 10: "Any unknown names should be ignored").
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_handshake}
  def decode(payload) when is_binary(payload) do
    case Bento.decode(payload) do
      {:ok, dict} when is_map(dict) -> {:ok, from_map(dict)}
      _ -> {:error, :invalid_handshake}
    end
  end

  @doc """
  Builds a handshake dictionary from a struct and bencodes it.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = handshake) do
    handshake
    |> to_map()
    |> Bento.encode!()
  end

  @doc false
  @spec from_map(map()) :: t()
  def from_map(dict) when is_map(dict) do
    %__MODULE__{
      m: parse_m(Map.get(dict, "m")),
      p: parse_port(Map.get(dict, "p")),
      v: parse_string(Map.get(dict, "v")),
      yourip: parse_ip(Map.get(dict, "yourip")),
      ipv4: parse_ipv4(Map.get(dict, "ipv4")),
      ipv6: parse_ipv6(Map.get(dict, "ipv6")),
      reqq: parse_positive_int(Map.get(dict, "reqq")),
      metadata_size: parse_positive_int(Map.get(dict, "metadata_size")),
      e: parse_encryption_flag(Map.get(dict, "e"))
    }
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = hs) do
    %{}
    |> maybe_put("m", hs.m, hs.m != %{})
    |> maybe_put("p", hs.p, is_integer(hs.p))
    |> maybe_put("v", hs.v, is_binary(hs.v) and hs.v != "")
    |> maybe_put("yourip", hs.yourip, valid_ip?(hs.yourip))
    |> maybe_put("ipv4", hs.ipv4, ipv4?(hs.ipv4))
    |> maybe_put("ipv6", hs.ipv6, ipv6?(hs.ipv6))
    |> maybe_put("reqq", hs.reqq, is_integer(hs.reqq))
    |> maybe_put("metadata_size", hs.metadata_size, is_integer(hs.metadata_size))
    |> maybe_put("e", hs.e, hs.e == 1)
  end

  @doc """
  Merges a subsequent peer handshake into existing state (BEP 10 re-handshake).

  The `m` dictionary is additive: only keys present in `incoming` are updated.
  An extension id of 0 removes/disables that extension. Other known fields replace
  the stored value when present in `incoming`.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = existing, %__MODULE__{} = incoming) do
    merged_m = merge_m(existing.m, incoming.m)

    existing
    |> Map.put(:m, merged_m)
    |> merge_scalar(:p, incoming.p)
    |> merge_scalar(:v, incoming.v)
    |> merge_scalar(:yourip, incoming.yourip)
    |> merge_scalar(:ipv4, incoming.ipv4)
    |> merge_scalar(:ipv6, incoming.ipv6)
    |> merge_scalar(:reqq, incoming.reqq)
    |> merge_scalar(:metadata_size, incoming.metadata_size)
    |> merge_scalar(:e, incoming.e)
  end

  @doc """
  Returns the peer's extension message id for `name`, or `nil`.

  Id 0 means the peer does not support / is disabling the extension (BEP 10 § `m`).
  """
  @spec peer_extension_id(t(), String.t()) :: pos_integer() | nil
  def peer_extension_id(%__MODULE__{m: m}, name) when is_binary(name) do
    case Map.get(m, name) do
      id when is_integer(id) and id > 0 -> id
      _ -> nil
    end
  end

  @doc """
  Returns whether the peer advertises support for `name` (id present and > 0).
  """
  @spec peer_supports?(t(), String.t()) :: boolean()
  def peer_supports?(handshake, name), do: peer_extension_id(handshake, name) != nil

  # --- m dictionary ---

  # BEP 10 § handshake message: `m` maps extension names to message ids local to the sender.
  @spec merge_m(map(), map()) :: map()
  defp merge_m(existing, incoming) when incoming == %{} do
    existing
  end

  defp merge_m(existing, incoming) do
    Enum.reduce(incoming, existing, fn
      {_name, 0}, acc ->
        # BEP 10: 0 disables an extension at runtime.
        acc

      {name, id}, acc when is_binary(name) and is_integer(id) and id in 1..255 ->
        Map.put(acc, name, id)

      _, acc ->
        acc
    end)
    |> prune_disabled(incoming)
  end

  # When peer explicitly sends name=>0, remove from merged map.
  @spec prune_disabled(map(), map()) :: map()
  defp prune_disabled(m, incoming) do
    incoming
    |> Enum.reduce(m, fn
      {name, 0}, acc when is_binary(name) -> Map.delete(acc, name)
      _, acc -> acc
    end)
  end

  @spec parse_m(term()) :: map()
  defp parse_m(m) when is_map(m) do
    m
    |> Enum.reduce(%{}, fn
      {name, id}, acc when is_binary(name) and is_integer(id) and id in 0..255 ->
        Map.put(acc, name, id)

      _, acc ->
        acc
    end)
  end

  defp parse_m(_), do: %{}

  @spec parse_port(term()) :: :inet.port_number() | nil
  defp parse_port(p) when is_integer(p) and p > 0 and p <= 65_535, do: p
  defp parse_port(_), do: nil

  @spec parse_string(term()) :: String.t() | nil
  defp parse_string(v) when is_binary(v), do: v
  defp parse_string(_), do: nil

  @spec parse_positive_int(term()) :: pos_integer() | nil
  defp parse_positive_int(n) when is_integer(n) and n > 0, do: n
  defp parse_positive_int(_), do: nil

  @spec parse_encryption_flag(term()) :: 1 | nil
  defp parse_encryption_flag(1), do: 1
  defp parse_encryption_flag(_), do: nil

  @spec parse_ip(term()) :: binary() | nil
  defp parse_ip(bin) when is_binary(bin) and byte_size(bin) in [4, 16], do: bin
  defp parse_ip(_), do: nil

  @spec parse_ipv4(term()) :: binary() | nil
  defp parse_ipv4(bin) when is_binary(bin) and byte_size(bin) == 4, do: bin
  defp parse_ipv4(_), do: nil

  @spec parse_ipv6(term()) :: binary() | nil
  defp parse_ipv6(bin) when is_binary(bin) and byte_size(bin) == 16, do: bin
  defp parse_ipv6(_), do: nil

  @spec valid_ip?(binary() | nil) :: boolean()
  defp valid_ip?(bin), do: is_binary(bin) and byte_size(bin) in [4, 16]

  @spec ipv4?(binary() | nil) :: boolean()
  defp ipv4?(bin), do: is_binary(bin) and byte_size(bin) == 4

  @spec ipv6?(binary() | nil) :: boolean()
  defp ipv6?(bin), do: is_binary(bin) and byte_size(bin) == 16

  @spec merge_scalar(t(), atom(), term()) :: t()
  defp merge_scalar(%__MODULE__{} = hs, _field, nil), do: hs
  defp merge_scalar(%__MODULE__{} = hs, field, value), do: Map.put(hs, field, value)

  @spec maybe_put(map(), String.t(), term(), boolean()) :: map()
  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
end

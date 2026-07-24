defmodule Peer.ConnectionManager.Queue do
  @moduledoc false

  # `:discovery` — tracker, DHT, LSD, magnet, productive re-offer, etc. PEX drops
  # must not revoke this tag. `{:pex, remote_id}` — one tag per remote ut_pex supplier.
  @type source :: :discovery | {:pex, binary()}
  @type key :: {:inet.ip_address(), :inet.port_number()}
  @type t :: %{key() => entry()}
  @type entry :: %__MODULE__{
          peer: Peer.t(),
          sources: MapSet.t(source())
        }

  defstruct [:peer, sources: MapSet.new()]

  @doc false
  @spec offer(t(), [Peer.t()], source()) :: t()
  def offer(queue, peers, source) when is_list(peers) do
    Enum.reduce(peers, queue, fn %Peer{} = peer, acc ->
      key = {peer.ip, peer.port}
      entry = Map.get(acc, key)
      Map.put(acc, key, merge_offer(entry, peer, source))
    end)
  end

  @doc false
  @spec revoke_pex(t(), binary(), [Peer.t() | key()]) :: t()
  def revoke_pex(queue, pex_source, endpoints)
      when is_binary(pex_source) and byte_size(pex_source) == 20 and is_list(endpoints) do
    tag = {:pex, pex_source}

    Enum.reduce(endpoints, queue, fn endpoint, acc ->
      key = endpoint_key(endpoint)

      case Map.get(acc, key) do
        nil ->
          acc

        %__MODULE__{sources: sources} = entry ->
          sources = MapSet.delete(sources, tag)

          if MapSet.size(sources) == 0 do
            Map.delete(acc, key)
          else
            Map.put(acc, key, %{entry | sources: sources})
          end
      end
    end)
  end

  @doc false
  @spec peers(t()) :: [Peer.t()]
  def peers(queue) when is_map(queue), do: Enum.map(queue, fn {_k, %__MODULE__{peer: p}} -> p end)

  @doc false
  @spec get_peer(t(), key()) :: Peer.t() | nil
  def get_peer(queue, key) do
    case Map.get(queue, key) do
      %__MODULE__{peer: peer} -> peer
      _ -> nil
    end
  end

  @spec merge_offer(entry() | nil, Peer.t(), source()) :: entry()
  defp merge_offer(nil, %Peer{} = peer, source) do
    %__MODULE__{peer: peer, sources: MapSet.new([source])}
  end

  defp merge_offer(%__MODULE__{peer: existing, sources: sources}, %Peer{} = incoming, source) do
    seed = existing.seed == true or incoming.seed == true

    peer = %Peer{
      incoming
      | seed: if(seed, do: true, else: incoming.seed)
    }

    %__MODULE__{peer: peer, sources: MapSet.put(sources, source)}
  end

  @spec endpoint_key(Peer.t() | key()) :: key()
  defp endpoint_key({ip, port}) when is_tuple(ip), do: {ip, port}
  defp endpoint_key(%Peer{ip: ip, port: port}), do: {ip, port}
end

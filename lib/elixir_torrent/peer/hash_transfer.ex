defmodule Peer.HashTransfer do
  @moduledoc """
  Outbound BEP 52 hash request correlation helpers.

  Callers receive `{:peer_hash_transfer, ref, result}` where `result` is:

    * `{:ok, request, hashes}` — verified against the pieces root
    * `{:reject, request}` — peer sent `hash_reject`
    * `{:timeout, request}` — no correlated response before the deadline
  """

  alias Peer.HashWire

  @type ref :: reference()

  @type result ::
          {:ok, HashWire.t(), [Torrent.Merkle.hash()]}
          | {:reject, HashWire.t()}
          | {:timeout, HashWire.t()}
          | {:disconnect, HashWire.t()}
          | {:error, :protocol_error, HashWire.t()}

  @doc false
  @spec notify(pid(), ref(), result()) :: :ok
  def notify(caller, ref, result) when is_pid(caller) do
    send(caller, {:peer_hash_transfer, ref, result})
    :ok
  end

  @doc false
  @spec request_key(HashWire.t()) :: tuple()
  def request_key(%HashWire{} = req) do
    {req.pieces_root, req.base_layer, req.index, req.length, req.proof_layers}
  end
end

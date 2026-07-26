defmodule Peer.Const do
  @moduledoc """
  Compile-time wire message ID constants for the BEP 3 peer protocol.
  """

  defmacro __using__(_opts) do
    quote do
      # Core Protocol
      @choke_id <<0>>
      @unchoke_id <<1>>
      @interested_id <<2>>
      @not_interested_id <<3>>
      @have_id <<4>>
      @bitfield_id <<5>>
      @request_id <<6>>
      @piece_id <<7>>
      @cancel_id <<8>>

      # DHT Extension
      @port_id <<9>>

      # Fast Extension
      @suggest_piece_id <<0x0D>>
      @have_all_id <<0x0E>>
      @have_none_id <<0x0F>>
      @reject_request_id <<0x10>>
      @allowed_fast_id <<0x11>>

      # BEP 10 Extension Protocol (LTEP) — wire message id 20, not a single-byte id here.
      # Extended payloads are framed in Peer.LTEP (handshake extended id 0).
      @extended_id <<20>>

      # BEP 52 Hash Transfer (top-level wire ids 21–23, not LTEP)
      @hash_request_id <<21>>
      @hashes_id <<22>>
      @hash_reject_id <<23>>
    end
  end
end

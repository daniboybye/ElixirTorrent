defmodule Peer.Const do
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

      # Hash Transfer Protocol
      # @hash_request_id 0x15
      # @hashed_id 0x16
      # @hash_reject_id 0x17
    end
  end
end

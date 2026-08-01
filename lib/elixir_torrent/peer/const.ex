defmodule Peer.Const do
  @moduledoc """
  Compile-time wire message ID constants for the BEP 3 peer protocol.

  Each id is declared once here, as an integer, and exposed in the two shapes the
  codebase actually reads off the wire:

    * `use Peer.Const` injects every id as the single **byte** it occupies on the
      wire (`<<0>>`). `Peer.Sender` matches those against whole message bodies
      (`<<@request_id, index::32, ...>>`), so it wants the binary form.
    * The `*_id/0` functions return the same id as an **integer**, for readers that
      have already peeled the id byte out of the length-prefixed frame — e.g.
      `Magnet.Connection`, whose BEP 9 drain decodes `<<message_id, rest::binary>>`
      and compares `message_id` as a number. Only the ids read that way today are
      exported; add more as callers need them.

  Both shapes are generated from the same attributes, so they cannot drift apart.
  """

  # Core Protocol (BEP 3 § peer messages)
  @choke_id 0
  @unchoke_id 1
  @interested_id 2
  @not_interested_id 3
  @have_id 4
  @bitfield_id 5
  @request_id 6
  @piece_id 7
  @cancel_id 8

  # DHT Extension (BEP 5)
  @port_id 9

  # Fast Extension (BEP 6)
  @suggest_piece_id 0x0D
  @have_all_id 0x0E
  @have_none_id 0x0F
  @reject_request_id 0x10
  @allowed_fast_id 0x11

  # BEP 10 Extension Protocol (LTEP) — wire message id 20, not a single-byte id here.
  # Extended payloads are framed in Peer.LTEP (handshake extended id 0).
  @extended_id 20

  # BEP 52 Hash Transfer (top-level wire ids 21–23, not LTEP)
  @hash_request_id 21
  @hashes_id 22
  @hash_reject_id 23

  defmacro __using__(_opts) do
    quote do
      # Core Protocol
      @choke_id <<unquote(@choke_id)>>
      @unchoke_id <<unquote(@unchoke_id)>>
      @interested_id <<unquote(@interested_id)>>
      @not_interested_id <<unquote(@not_interested_id)>>
      @have_id <<unquote(@have_id)>>
      @bitfield_id <<unquote(@bitfield_id)>>
      @request_id <<unquote(@request_id)>>
      @piece_id <<unquote(@piece_id)>>
      @cancel_id <<unquote(@cancel_id)>>

      # DHT Extension
      @port_id <<unquote(@port_id)>>

      # Fast Extension
      @suggest_piece_id <<unquote(@suggest_piece_id)>>
      @have_all_id <<unquote(@have_all_id)>>
      @have_none_id <<unquote(@have_none_id)>>
      @reject_request_id <<unquote(@reject_request_id)>>
      @allowed_fast_id <<unquote(@allowed_fast_id)>>

      # BEP 10 Extension Protocol (LTEP)
      @extended_id <<unquote(@extended_id)>>

      # BEP 52 Hash Transfer
      @hash_request_id <<unquote(@hash_request_id)>>
      @hashes_id <<unquote(@hashes_id)>>
      @hash_reject_id <<unquote(@hash_reject_id)>>
    end
  end

  @doc false
  @spec choke_id() :: 0
  def choke_id, do: @choke_id

  @doc false
  @spec unchoke_id() :: 1
  def unchoke_id, do: @unchoke_id

  @doc false
  @spec interested_id() :: 2
  def interested_id, do: @interested_id
end

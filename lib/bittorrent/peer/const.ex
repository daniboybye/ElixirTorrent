defmodule Peer.Const do
  defmacro message_id() do
    quote do
      @choke_id 0
      @unchoke_id 1
      @interested_id 2
      @not_interested_id 3
      @have_id 4
      @bitfield_id 5
      @request_id 6
      @piece_id 7
      @cancel_id 8
      @port_id 9

      @timeout 120_000
    end
  end
end

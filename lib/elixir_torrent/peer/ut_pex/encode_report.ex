defmodule Peer.UtPex.EncodeReport do
  @moduledoc false

  # Returned by `Peer.UtPex.encode_delta/3` so per-connection outbound state advances
  # by what actually hit the wire — not by the pre-truncation candidate list.
  defstruct initial?: false,
            added_total: 0,
            dropped_total: 0,
            added_encoded: 0,
            dropped_encoded: 0,
            added_truncated: 0,
            dropped_truncated: 0,
            added_entries: [],
            dropped_endpoints: []

  @type t :: %__MODULE__{
          initial?: boolean(),
          added_total: non_neg_integer(),
          dropped_total: non_neg_integer(),
          added_encoded: non_neg_integer(),
          dropped_encoded: non_neg_integer(),
          added_truncated: non_neg_integer(),
          dropped_truncated: non_neg_integer(),
          added_entries: [Peer.UtPex.Entry.t()],
          dropped_endpoints: [Peer.UtPex.endpoint()]
        }
end

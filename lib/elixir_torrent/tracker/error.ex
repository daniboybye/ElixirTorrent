defmodule Tracker.Error do
  @moduledoc """
  Structured tracker failure (reason plus optional `Retry-After` hint).
  """

  @enforce_keys [:reason]
  defstruct [:reason, :retry_in]

  @type t :: %__MODULE__{
          # A tracker's own `failure reason` string, an atom (`:timeout`), or a
          # classified tuple carrying evidence (`{:http_status, 403}`,
          # `{:bind_family_mismatch, :inet6}`, `{:bad_response, msg}`).
          reason: term(),
          retry_in: non_neg_integer() | binary() | nil
        }
end

defmodule Tracker.Error do
  @moduledoc """
  Structured tracker failure (reason plus optional `Retry-After` hint).
  """

  @enforce_keys [:reason]
  defstruct [:reason, :retry_in]

  @type t :: %__MODULE__{
          reason: String.t() | binary() | atom(),
          retry_in: non_neg_integer() | binary() | nil
        }
end

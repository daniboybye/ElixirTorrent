defmodule Tracker.Error do
  @enforce_keys [:reason]
  defstruct [:reason, :retry_in]

  @type t :: %__MODULE__{
          reason: String.t() | binary() | atom(),
          retry_in: binary()
        }
end

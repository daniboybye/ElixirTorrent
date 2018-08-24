defmodule Tracker.Error do
  @enforce_keys [:reason]
  defstruct [:reason]

  @type t :: %__MODULE__{
          reason: String.t() | binary() | atom()
        }
end

defmodule Peer.UtPex.InboundRate do
  @moduledoc false

  @window_ms 60_000

  @type state :: %{
          initial?: boolean(),
          anchor_ms: non_neg_integer() | nil
        }

  @doc false
  @spec initial() :: state()
  def initial, do: %{initial?: true, anchor_ms: nil}

  @doc """
  Gate inbound PEX before decode/ingest. Initial message always passes; afterwards at most
  one accepted message per #{@window_ms}ms window anchored on the last accept.
  """
  @spec gate(state(), non_neg_integer()) :: {:allow, state(), :initial | :delta} | {:reject, state()}
  def gate(%{initial?: true} = state, now_ms) do
    {:allow, %{state | initial?: false, anchor_ms: now_ms}, :initial}
  end

  def gate(%{anchor_ms: anchor}, now_ms) when is_integer(anchor) and now_ms - anchor < @window_ms do
    {:reject, %{initial?: false, anchor_ms: anchor}}
  end

  def gate(_state, now_ms) do
    {:allow, %{initial?: false, anchor_ms: now_ms}, :delta}
  end

  @doc false
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms
end

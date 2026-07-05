defmodule UTP.LEDBAT do
  @moduledoc """
  LEDBAT congestion control for uTP (BEP 29).

  Target one-way delay: 100 ms. Uses a sliding minimum base delay over ~2 minutes
  and adjusts `max_window` (bytes in flight) from measured queueing delay.

  Simplifications vs libutp:

  * `max_cwnd_increase` is fixed rather than derived from packet size tiers.
  * Delay history is a bounded sample list, not a precise 2-minute sliding window.
  """

  @target_delay_us 100_000
  @max_cwnd_increase 3_000
  @loss_factor 0.5
  @history_limit 240

  defstruct [
    max_window: 65_536,
    base_delay: nil,
    delay_samples: [],
    last_off_target: 0
  ]

  @type t :: %__MODULE__{
          max_window: non_neg_integer(),
          base_delay: non_neg_integer() | nil,
          delay_samples: [{non_neg_integer(), integer()}],
          last_off_target: integer()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_delay(t(), non_neg_integer()) :: t()
  def record_delay(%__MODULE__{} = state, timestamp_difference_us) when timestamp_difference_us >= 0 do
    now_ms = System.monotonic_time(:millisecond)

    samples =
      [{timestamp_difference_us, now_ms} | state.delay_samples]
      |> Enum.take(@history_limit)

    base_delay =
      samples
      |> Enum.map(&elem(&1, 0))
      |> then(fn
        [] -> state.base_delay
        values -> Enum.min(values)
      end)

    our_delay =
      if base_delay do
        max(timestamp_difference_us - base_delay, 0)
      else
        0
      end

    off_target = @target_delay_us - our_delay

    %{state | base_delay: base_delay, delay_samples: samples, last_off_target: off_target}
  end

  @spec grow_window(t(), non_neg_integer(), non_neg_integer()) :: t()
  def grow_window(%__MODULE__{} = state, outstanding_bytes, peer_wnd_size) do
    target = min(state.max_window, peer_wnd_size)

    delay_factor =
      if @target_delay_us == 0 do
        0.0
      else
        state.last_off_target / @target_delay_us
      end

    window_factor =
      if target <= 0 do
        0.0
      else
        outstanding_bytes / target
      end

    scaled_gain = trunc(@max_cwnd_increase * delay_factor * window_factor)
    max_window = max(state.max_window + scaled_gain, 0)
    %{state | max_window: max_window}
  end

  @spec on_loss(t()) :: t()
  def on_loss(%__MODULE__{} = state) do
    max_window = max(trunc(state.max_window * @loss_factor), 150)
    %{state | max_window: max_window}
  end

  @spec on_timeout(t()) :: t()
  def on_timeout(%__MODULE__{} = state) do
    %{state | max_window: 150}
  end

  @spec target_delay_us() :: 100_000
  def target_delay_us, do: @target_delay_us
end

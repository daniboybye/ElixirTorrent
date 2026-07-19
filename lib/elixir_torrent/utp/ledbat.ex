defmodule UTP.LEDBAT do
  @moduledoc """
  LEDBAT congestion control for uTP (BEP 29).

  Target one-way delay: 100 ms. Uses a sliding minimum base delay over the
  last 2 minutes of samples and adjusts `max_window` (bytes in flight) from
  measured queueing delay.

  Deviations from libutp we accept:

  * `max_cwnd_increase` is fixed rather than derived from packet-size tiers.
  * Slow start is a plain multiplicative ramp until we first hit the target
    or observe a loss/timeout; libutp's slow-start uses a running SS threshold.
  """

  @target_delay_us 100_000
  @max_cwnd_increase 3_000
  @loss_factor 0.5
  # BEP 29 says the base delay minimum is taken over the last ~2 minutes.
  # Previous code used a 240-sample cap, which drifts with sample rate: a
  # slow link could hold minutes of stale samples, a fast link could keep
  # only seconds worth. Enforce wall-clock ageing directly.
  @history_ms 120_000
  # Hard cap to bound memory when the sample rate spikes; well above what a
  # 2-minute window at typical uTP ACK cadence produces.
  @history_hard_limit 2_048
  # Absolute upper bound on max_window regardless of grow signal. Prevents an
  # unbounded ramp during long low-delay stretches from parking megabytes in
  # flight (matches libutp's default MAX_CWND_INCREASE_BYTES_PER_RTT scaling
  # ceiling in spirit — a real number rather than "however big last_off_target
  # keeps pushing it").
  @max_window_ceiling 1_048_576
  # Initial max_window in bytes when a connection is fresh. Two MTU-ish
  # packets, i.e. slow-start start point (libutp: MIN_WINDOW_SIZE * 2ish).
  @initial_max_window 3_000

  defstruct [
    max_window: @initial_max_window,
    base_delay: nil,
    delay_samples: [],
    last_off_target: 0,
    slow_start: true
  ]

  @type t :: %__MODULE__{
          max_window: non_neg_integer(),
          base_delay: non_neg_integer() | nil,
          delay_samples: [{non_neg_integer(), integer()}],
          last_off_target: integer(),
          slow_start: boolean()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_delay(t(), non_neg_integer()) :: t()
  def record_delay(%__MODULE__{} = state, timestamp_difference_us) when timestamp_difference_us >= 0 do
    now_ms = System.monotonic_time(:millisecond)

    samples =
      [{timestamp_difference_us, now_ms} | state.delay_samples]
      |> Enum.filter(fn {_v, t} -> now_ms - t <= @history_ms end)
      |> Enum.take(@history_hard_limit)

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
  def grow_window(%__MODULE__{slow_start: true} = state, outstanding_bytes, peer_wnd_size) do
    # In slow start, cwnd doubles until we either hit the peer's advertised
    # window or the queue starts filling (off_target <= 0 means our delay is
    # at or over the 100 ms target). Then flip to LEDBAT proportional gain.
    if state.last_off_target <= 0 do
      %{state | slow_start: false}
      |> grow_window(outstanding_bytes, peer_wnd_size)
    else
      target = if peer_wnd_size > 0, do: peer_wnd_size, else: @max_window_ceiling
      grown = state.max_window + @max_cwnd_increase
      max_window = grown |> min(target) |> min(@max_window_ceiling)

      state = %{state | max_window: max_window}
      if max_window >= target, do: %{state | slow_start: false}, else: state
    end
  end

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

    max_window =
      state.max_window
      |> Kernel.+(scaled_gain)
      |> max(0)
      |> min(@max_window_ceiling)

    %{state | max_window: max_window}
  end

  @spec on_loss(t()) :: t()
  def on_loss(%__MODULE__{} = state) do
    max_window = max(trunc(state.max_window * @loss_factor), 150)
    %{state | max_window: max_window, slow_start: false}
  end

  @spec on_timeout(t()) :: t()
  def on_timeout(%__MODULE__{} = state) do
    %{state | max_window: 150, slow_start: false}
  end

  @spec target_delay_us() :: 100_000
  def target_delay_us, do: @target_delay_us
end

defmodule DHT.Candidates do
  @moduledoc """
  BEP 5 § Routing Table — nodes seen only as the source of an inbound query,
  waiting to prove they answer ours.

  BEP 5 calls a node good when it "has responded to one of our queries", or has
  queried us *and* has responded before. A first-seen query source has done
  neither: its source address may be spoofed, or unreachable behind a NAT that
  only lets its own outbound traffic back in. So it is not inserted; it becomes
  a candidate, `DHT` pings the address the query came from, and only a valid
  response (the normal response path: BEP 42 check, `learn_remote_contact`,
  ping-before-evict) puts it in the routing table. No answer within the query
  timeout drops it.

  The list is the one piece of state a stranger can make us create, so every
  dimension is bounded:

    * at most `max` candidates (64) and `max_per_ip` (2) per source IP;
    * each lives at most `ttl_ms` (30 s) — the ping timeout normally ends it
      long before, the TTL only guards against a lost timeout;
    * at most `max_probes` (16) new probes per `window_ms` (1 s), so a flood of
      spoofed queries buys at most that many pings per second — one small ping
      per admitted query, never more, to the address that sent it.

  Pure: every function takes `now_ms`, and the limits can be overridden through
  `opts` (tests use that; `DHT` runs on the defaults).
  """

  @default_max 64
  @default_max_per_ip 2
  @default_ttl_ms 30_000
  @default_max_probes 16
  @default_window_ms 1_000

  @type key :: {:inet.ip_address(), :inet.port_number()}
  @type candidate :: %{
          id: <<_::160>>,
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          added_ms: integer()
        }
  @type drop_reason :: :pending | :full | :per_ip | :rate | :busy
  @type outcome :: :verified | :unanswered | :rejected | :unsent
  @type t :: %__MODULE__{
          entries: %{key() => candidate()},
          window_start_ms: integer() | nil,
          window_count: non_neg_integer(),
          counters: %{atom() => non_neg_integer()}
        }

  defstruct entries: %{},
            window_start_ms: nil,
            window_count: 0,
            counters: %{
              admitted: 0,
              verified: 0,
              unanswered: 0,
              rejected: 0,
              unsent: 0,
              expired: 0,
              dropped_pending: 0,
              dropped_full: 0,
              dropped_per_ip: 0,
              dropped_rate: 0,
              dropped_busy: 0
            }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @type contact :: %{
          required(:id) => <<_::160>>,
          required(:ip) => :inet.ip_address(),
          required(:port) => :inet.port_number(),
          optional(atom()) => term()
        }

  @spec key(%{
          required(:ip) => :inet.ip_address(),
          required(:port) => :inet.port_number(),
          optional(atom()) => term()
        }) :: key()
  def key(%{ip: ip, port: port}), do: {ip, port}

  @doc """
  Admit `contact` as a candidate to probe now, or say why not.

  `{:ok, t}` means the caller should ping the contact's address; anything else
  means no packet. An address already being probed is not probed twice.
  """
  @spec admit(t(), contact(), integer(), keyword()) :: {:ok, t()} | {:drop, drop_reason(), t()}
  def admit(%__MODULE__{} = candidates, contact, now_ms, opts \\ []) do
    candidates =
      candidates
      |> expire(now_ms, opts)
      |> roll_window(now_ms, opts)

    case refusal(candidates, contact, opts) do
      nil -> {:ok, put_candidate(candidates, contact, now_ms)}
      reason -> drop(candidates, reason)
    end
  end

  @spec refusal(t(), contact(), keyword()) :: drop_reason() | nil
  defp refusal(candidates, %{ip: ip} = contact, opts) do
    cond do
      Map.has_key?(candidates.entries, key(contact)) -> :pending
      map_size(candidates.entries) >= Keyword.get(opts, :max, @default_max) -> :full
      count_ip(candidates, ip) >= Keyword.get(opts, :max_per_ip, @default_max_per_ip) -> :per_ip
      candidates.window_count >= Keyword.get(opts, :max_probes, @default_max_probes) -> :rate
      true -> nil
    end
  end

  @spec put_candidate(t(), contact(), integer()) :: t()
  defp put_candidate(candidates, %{id: id, ip: ip, port: port} = contact, now_ms) do
    entry = %{id: id, ip: ip, port: port, added_ms: now_ms}

    bump(
      %{
        candidates
        | entries: Map.put(candidates.entries, key(contact), entry),
          window_count: candidates.window_count + 1
      },
      :admitted
    )
  end

  @doc "Count a contact refused before it reached `admit/4` (e.g. no free query slot)."
  @spec refuse(t(), drop_reason()) :: t()
  def refuse(%__MODULE__{} = candidates, reason), do: elem(drop(candidates, reason), 2)

  @doc "End a candidate's probe with `outcome`. Unknown keys are ignored."
  @spec resolve(t(), key(), outcome()) :: t()
  def resolve(%__MODULE__{} = candidates, key, outcome) do
    case Map.pop(candidates.entries, key) do
      {nil, _entries} -> candidates
      {_entry, entries} -> bump(%{candidates | entries: entries}, outcome)
    end
  end

  @doc "Drop candidates older than the TTL."
  @spec expire(t(), integer(), keyword()) :: t()
  def expire(%__MODULE__{} = candidates, now_ms, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    {expired, live} =
      Enum.split_with(candidates.entries, fn {_key, %{added_ms: added}} ->
        now_ms - added >= ttl
      end)

    case expired do
      [] ->
        candidates

      _ ->
        counters = Map.update!(candidates.counters, :expired, &(&1 + length(expired)))
        %{candidates | entries: Map.new(live), counters: counters}
    end
  end

  @spec member?(t(), key()) :: boolean()
  def member?(%__MODULE__{entries: entries}, key), do: Map.has_key?(entries, key)

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc "Current size plus lifetime counters, for logs and `DHT.routing_stats/0`."
  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = candidates),
    do: Map.put(candidates.counters, :candidates, size(candidates))

  @spec roll_window(t(), integer(), keyword()) :: t()
  defp roll_window(%__MODULE__{window_start_ms: start} = candidates, now_ms, opts) do
    window = Keyword.get(opts, :window_ms, @default_window_ms)

    if start == nil or now_ms - start >= window do
      %{candidates | window_start_ms: now_ms, window_count: 0}
    else
      candidates
    end
  end

  @spec count_ip(t(), :inet.ip_address()) :: non_neg_integer()
  defp count_ip(%__MODULE__{entries: entries}, ip),
    do: Enum.count(entries, fn {{entry_ip, _port}, _entry} -> entry_ip == ip end)

  @drop_counters %{
    pending: :dropped_pending,
    full: :dropped_full,
    per_ip: :dropped_per_ip,
    rate: :dropped_rate,
    busy: :dropped_busy
  }

  @spec drop(t(), drop_reason()) :: {:drop, drop_reason(), t()}
  defp drop(candidates, reason),
    do: {:drop, reason, bump(candidates, Map.fetch!(@drop_counters, reason))}

  @spec bump(t(), atom()) :: t()
  defp bump(candidates, counter),
    do: %{candidates | counters: Map.update(candidates.counters, counter, 1, &(&1 + 1))}
end

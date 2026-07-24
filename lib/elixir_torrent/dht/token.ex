defmodule DHT.Token do
  @moduledoc """
  BEP 5 § Overview — opaque announce tokens tied to requester IP and a rotating secret.

  Tokens are SHA1(ip <> secret) truncated to 8 bytes. The secret rotates every five
  minutes; tokens up to ten minutes old remain valid (current + previous secret).
  """

  @rotate_ms 5 * 60 * 1_000
  @accept_ms 10 * 60 * 1_000
  @token_size 8

  alias DHT.BEP42

  @type t :: %__MODULE__{
          current_secret: binary(),
          previous_secret: binary() | nil,
          rotated_at_ms: non_neg_integer()
        }

  defstruct [:current_secret, :previous_secret, :rotated_at_ms]

  @doc "Create a token store with a fresh secret."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    %__MODULE__{
      current_secret: random_secret(),
      previous_secret: nil,
      rotated_at_ms: now
    }
  end

  @doc "Rotate the secret if five minutes have elapsed (BEP 5 § tokens)."
  @spec maybe_rotate(t(), keyword()) :: t()
  def maybe_rotate(%__MODULE__{} = store, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())

    if now - store.rotated_at_ms >= @rotate_ms do
      %__MODULE__{
        current_secret: random_secret(),
        previous_secret: store.current_secret,
        rotated_at_ms: now
      }
    else
      store
    end
  end

  @doc "Issue an opaque token for `ip` using the current secret."
  @spec issue(t(), :inet.ip_address()) :: binary()
  def issue(%__MODULE__{} = store, ip) do
    store
    |> maybe_rotate()
    |> do_issue(ip, & &1.current_secret)
  end

  @doc "Issue a token only when `node_id` is BEP-42-valid for `ip` (or locally exempt)."
  @spec issue_for_node(t(), <<_::160>>, :inet.ip_address()) :: binary() | nil
  def issue_for_node(%__MODULE__{} = store, <<node_id::binary-size(20)>>, ip) do
    if BEP42.valid_or_exempt?(node_id, ip), do: issue(store, ip)
  end

  @doc "Validate a token for `ip`, accepting current or previous secret."
  @spec valid?(t(), :inet.ip_address(), binary(), keyword()) :: boolean()
  def valid?(%__MODULE__{} = store, ip, token, opts \\ []) do
    now = Keyword.get(opts, :now_ms, now_ms())
    store = maybe_rotate(store, now_ms: now)

    cond do
      not is_binary(token) or byte_size(token) != @token_size ->
        false

      token == do_issue(store, ip, & &1.current_secret) ->
        true

      is_binary(store.previous_secret) and
        now - store.rotated_at_ms <= @accept_ms and
          token == do_issue(store, ip, & &1.previous_secret) ->
        true

      true ->
        false
    end
  end

  @spec do_issue(t(), :inet.ip_address(), (t() -> binary())) :: binary()
  defp do_issue(store, ip, secret_fun) do
    secret = secret_fun.(store)
    :crypto.hash(:sha, [ip_binary(ip), secret]) |> binary_part(0, @token_size)
  end

  @spec ip_binary(:inet.ip_address()) :: binary()
  defp ip_binary({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_binary({s1, s2, s3, s4, s5, s6, s7, s8}),
    do: <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>>

  defp ip_binary(_), do: <<>>

  @spec random_secret() :: binary()
  defp random_secret, do: :crypto.strong_rand_bytes(20)

  @spec now_ms() :: non_neg_integer()
  defp now_ms, do: System.monotonic_time(:millisecond)
end

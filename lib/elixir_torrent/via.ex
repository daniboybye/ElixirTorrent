defmodule Via do
  @moduledoc """
  Registry naming helper: `{:via, Registry, {Registry, {key, module}}}`.
  """

  defmacro __using__(_opts) do
    quote do
      defp via(key) do
        {:via, Registry, {Registry, {key, __MODULE__}}}
      end
    end
  end
end

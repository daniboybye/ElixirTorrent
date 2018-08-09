defmodule Via do
  defmacro make() do
    quote do
      defp via(key) do
        {:via, Registry, {Registry, {key, __MODULE__}}}
      end
    end
  end
end

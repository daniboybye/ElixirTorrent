defmodule Via do
  defmacro make() do
		quote do
      defp via(key) do
       {:via, Registry, {RegistryProcesses, {key, __MODULE__}}}
      end
    end
  end
end
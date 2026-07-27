# PropCheck 1.5.0 has no post-release Elixir 1.20 compatibility tag. Apply the
# minimal warning-only upstream-source adjustments and fail closed on source drift.
patches = [
  {
    "lib/counterstrike.ex",
    "  use GenServer\n  require Logger\n\n  defstruct",
    "  use GenServer\n\n  defstruct"
  },
  {
    "lib/properties.ex",
    "  alias PropCheck.CounterStrike\n  require Logger\n\n  @doc",
    "  alias PropCheck.CounterStrike\n\n  @doc"
  },
  {
    "lib/statem.ex",
    "    import PropCheck.Logger, only: [log_debug: 1]\n    require PropCheck\n    require PropCheck.BasicTypes\n\n    log_debug",
    "    import PropCheck.Logger, only: [log_debug: 1]\n    require PropCheck\n\n    log_debug"
  },
  {
    "lib/statem/model_dsl.ex",
    "  def more_commands(n, cmd_type) do\n    require PropCheck\n    require PropCheck.BasicTypes\n\n    PropCheck.sized",
    "  def more_commands(n, cmd_type) do\n    require PropCheck\n\n    PropCheck.sized"
  },
  {
    "lib/result.ex",
    "  def handle_call({:message, fmt, args}, _from, state) do",
    "  def handle_call({:message, fmt, args}, _from, %__MODULE__{} = state) do"
  }
]

dependency_root = Path.expand("../deps/propcheck", __DIR__)

Enum.each(patches, fn {path, before, after_patch} ->
  dependency_path = Path.join(dependency_root, path)
  source = File.read!(dependency_path)

  cond do
    length(:binary.matches(source, before)) == 1 ->
      File.write!(dependency_path, String.replace(source, before, after_patch))

    String.contains?(source, after_patch) ->
      :ok

    true ->
      raise "PropCheck compatibility patch no longer applies to #{dependency_path}"
  end
end)

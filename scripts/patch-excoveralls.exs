# ExCoveralls 0.18.5 predates Elixir 1.20's stricter unused-require and type
# warnings. Apply warning-only compatibility changes and fail closed on drift.
patches = [
  {
    "lib/excoveralls/html/view.ex",
    "  require EEx\n  require ExCoveralls.Html.Safe\n\n  alias ExCoveralls.Html.Safe",
    "  alias ExCoveralls.Html.Safe",
    1
  },
  {
    "lib/excoveralls/circle.ex",
    """
      defp get_message! do
        case System.cmd("git", ["log", "-1", "--pretty=format:%s"]) do
          {message, _} -> message
          _ -> "[no commit message]"
        end
      end
    """,
    """
      defp get_message! do
        {message, _status} = System.cmd("git", ["log", "-1", "--pretty=format:%s"])
        message
      end
    """,
    1
  },
  {
    "lib/excoveralls/gitlab.ex",
    """
      defp get_committer do
        case System.cmd("git", ["log", "-1", "--format=%an"]) do
          {committer, _} -> String.trim(committer)
          _ -> "[no committer name]"
        end
      end
    """,
    """
      defp get_committer do
        {committer, _status} = System.cmd("git", ["log", "-1", "--format=%an"])
        String.trim(committer)
      end
    """,
    1
  },
  {
    "lib/excoveralls/semaphore.ex",
    """
      defp get_message! do
        case System.cmd("git", ["log", "-1", "--pretty=format:%s"]) do
          {message, _} -> message
          _ -> "[no commit message]"
        end
      end
    """,
    """
      defp get_message! do
        {message, _status} = System.cmd("git", ["log", "-1", "--pretty=format:%s"])
        message
      end
    """,
    1
  },
  {
    "lib/excoveralls/poster.ex",
    "        [cacertfile: String.to_charlist(CAStore.file_path())]",
    "        [cacertfile: String.to_charlist(apply(CAStore, :file_path, []))]",
    2
  }
]

dependency_root = Path.expand("../deps/excoveralls", __DIR__)

Enum.each(patches, fn {path, before, after_patch, expected_matches} ->
  dependency_path = Path.join(dependency_root, path)
  source = File.read!(dependency_path)
  before_matches = length(:binary.matches(source, before))
  after_matches = length(:binary.matches(source, after_patch))

  cond do
    before_matches == expected_matches ->
      File.write!(dependency_path, String.replace(source, before, after_patch))

    before_matches == 0 and after_matches == expected_matches ->
      :ok

    true ->
      raise "ExCoveralls compatibility patch no longer applies to #{dependency_path}"
  end
end)

defmodule ElixirTorrent.MixProject do
  use Mix.Project

  @version "0.5.1"

  def project do
    [
      app: :elixir_torrent,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: elixirc_options(),
      description: description(),
      package: package(),
      source_url: source_url(),
      docs: docs(),
      deps: deps(),
      escript: escript(),
      aliases: aliases(),
      # Defensive and staged protocol branches intentionally retain fallback
      # clauses that Dialyzer proves unreachable with today's implementations.
      dialyzer: [flags: [:no_match]]
    ]
  end

  defp elixirc_options do
    [
      warnings_as_errors: true
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirTorrentApplication, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:bento, "~> 1.0.0"},
      {:recon, "~> 2.5.6"},
      {:logger_file_backend, "~> 0.0.14"},
      {:logger_backends, "~> 1.0"},
      {:httpoison, "~> 3.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
    ]
  end

  defp escript do
    [main_module: ElixirTorrent]
  end

  defp aliases do
    [quality: ["compile --warnings-as-errors", "dialyzer", "credo --only warning"]]
  end

  @spec description() :: String.t()
  defp description do
    "BitTorrent engine for Elixir — download, seed, session persistence, and a stable OTP public API."
  end

  @spec source_url() :: String.t()
  defp source_url do
    "https://github.com/daniboybye/ElixirTorrent"
  end

  @spec hexdocs_url() :: String.t()
  defp hexdocs_url do
    "https://hexdocs.pm/elixir_torrent"
  end

  @spec changelog_url() :: String.t()
  defp changelog_url do
    "https://hexdocs.pm/elixir_torrent/changelog.html"
  end

  @spec package() :: keyword()
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => source_url(),
        "Documentation" => hexdocs_url(),
        "Changelog" => changelog_url(),
        "ElixirTorrent Web" => "https://github.com/daniboybye/ElixirTorrentWebUI"
      },
      files: [
        "lib",
        "config",
        "mix.exs",
        "mix.lock",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        ".formatter.exs"
      ]
    ]
  end

  @spec docs() :: keyword()
  defp docs do
    [
      main: "readme",
      name: "ElixirTorrent",
      source_ref: "#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_extras: [
        Introduction: ~r/README.md/,
        Project: ~r/CHANGELOG.md/
      ],
      groups_for_modules: [
        "Public API": [ElixirTorrent, Torrents]
      ],
      filter_modules: fn module, _metadata ->
        module in [ElixirTorrent, Torrents]
      end
    ]
  end
end

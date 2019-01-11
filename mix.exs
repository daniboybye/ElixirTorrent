defmodule Bittorrent.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_torrent,
      version: "0.1.0",
      elixir: "~> 1.7.4 ",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirTorrent, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.0.0-rc.4", only: [:dev], runtime: false},
      {:bento, "~> 0.9"},
      {:recon, "~> 2.4"},
      {:logger_file_backend, "~> 0.0.10", github: "onkel-dirtus/logger_file_backend"},
      {:httpoison, "~> 1.1"},
      {:mock, "~> 0.3.2", only: :test}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
    ]
  end
end

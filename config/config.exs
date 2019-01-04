use Mix.Config

config :logger, backends: [{LoggerFileBackend, :info}, {LoggerFileBackend, :error}, {LoggerFileBackend, :warn}]

config :logger, :info,
  path: "info.log",
  level: :info

config :logger, :error,
  path: "error.log",
  level: :error

config :logger, :warn,
  path: "warn.log",
  level: :warn

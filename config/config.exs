import Config

config :logger, :debug_log,
  path: "debug.log",
  level: :debug

# BEP 5 DHT — enabled by default on desktop; set enabled: false to disable.
config :elixir_torrent, :dht, enabled: true

# :test overrides every subsystem that would otherwise reach the network.
if config_env() == :test do
  import_config "test.exs"
end
